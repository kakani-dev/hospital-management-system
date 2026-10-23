// Jenkins pipeline mirroring .github/workflows/ci.yml.
// GitHub Actions remains the REQUIRED PR gate; this pipeline is an optional mirror for teams on Jenkins.
// Path filters and pass-cache skips live in GitHub Actions only. This Jenkins mirror still runs the full suite.
// Requirements and setup: infra/jenkins/README.md (Docker Pipeline, JUnit, MSTest, Workspace Cleanup plugins).
// Uses only throwaway containers and synthetic data. No deploy steps, no secrets required.

pipeline {
  agent none

  options {
    buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '5'))
    timeout(time: 60, unit: 'MINUTES')
    timestamps()
    disableConcurrentBuilds(abortPrevious: true)
    skipStagesAfterUnstable()
  }

  environment {
    DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    DOTNET_NOLOGO = '1'
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    CI = 'true'
    // Image tags in one place. Keep PLAYWRIGHT_IMAGE in sync with @playwright/test in package.json.
    NODE_IMAGE = 'node:24-bookworm'
    DOTNET_IMAGE = 'mcr.microsoft.com/dotnet/sdk:10.0'
    POSTGRES_IMAGE = 'postgres:17'
    PLAYWRIGHT_IMAGE = 'mcr.microsoft.com/playwright:v1.63.0-noble'
    // Throwaway sidecar credentials (container lives only for the stage). Not a secret.
    PG_PASSWORD = 'postgres'
  }

  stages {
    stage('Build & test') {
      parallel {
        stage('Web') {
          agent {
            docker {
              image 'node:24-bookworm'           // = NODE_IMAGE
              label 'docker'
            }
          }
          environment {
            npm_config_cache = "${WORKSPACE}/.npm"
          }
          steps {
            dir('apps/web') {
              sh 'npm ci --no-audit --no-fund'
              sh 'npm run lint'
              sh 'npx vitest run --reporter=default --reporter=junit --outputFile.junit=../../reports/web-junit.xml'
              sh 'npm run build'
            }
          }
          post {
            always {
              junit testResults: 'reports/web-junit.xml', allowEmptyResults: true
            }
            cleanup {
              cleanWs()
            }
          }
        }

        stage('API') {
          agent {
            docker {
              image 'mcr.microsoft.com/dotnet/sdk:10.0' // = DOTNET_IMAGE
              label 'docker'
            }
          }
          environment {
            DOTNET_CLI_HOME = "${WORKSPACE}/.dotnet-home"
            NUGET_PACKAGES = "${WORKSPACE}/.nuget/packages"
          }
          steps {
            sh 'dotnet restore backend/Hms.slnx'
            sh 'dotnet build backend/Hms.slnx -c Release --no-restore -warnaserror'
            sh '''
              dotnet test backend/Hms.slnx -c Release --no-build \
                --filter "Category!=Database" \
                --logger "trx;LogFilePrefix=unit" --results-directory test-results
            '''
            // Self-contained services + edge for the E2E stage (the Playwright image has no .NET SDK).
            sh '''
              set -euo pipefail
              publish() { dotnet publish "backend/$1" -c Release -r linux-x64 --self-contained -o "api-publish/$2"; }
              publish services/identity/Hms.Identity.Api identity
              publish services/patients/Hms.Patients.Api patients
              publish services/scheduling/Hms.Scheduling.Api scheduling
              publish edge/Hms.Edge edge
            '''
            stash name: 'api-publish', includes: 'api-publish/**'
          }
          post {
            always {
              mstest testResultsFile: 'test-results/**/*.trx', failOnError: false, keepLongStdio: true
            }
            cleanup {
              cleanWs()
            }
          }
        }

        stage('Database (SQL/RLS + integration)') {
          agent { label 'docker' }
          steps {
            script {
              docker.image(env.POSTGRES_IMAGE).withRun("-e POSTGRES_PASSWORD=${env.PG_PASSWORD}") { pg ->
                // psql client from the same image; waits for the sidecar, then migrations + seed + SQL tests.
                docker.image(env.POSTGRES_IMAGE).inside("--link ${pg.id}:db") {
                  sh 'until pg_isready -h db -U postgres; do sleep 1; done'
                  sh 'DATABASE_URL="postgresql://postgres:${PG_PASSWORD}@db:5432/postgres" bash supabase/scripts/run-sql-tests.sh'
                }
                docker.image(env.DOTNET_IMAGE).inside("--link ${pg.id}:db") {
                  withEnv([
                    "DOTNET_CLI_HOME=${env.WORKSPACE}/.dotnet-home",
                    "NUGET_PACKAGES=${env.WORKSPACE}/.nuget/packages",
                    "HMS_DB_TEST_CONNECTION=Host=db;Port=5432;Database=hms_sql_test;Username=postgres;Password=${env.PG_PASSWORD}",
                    // Local-only login role created by supabase/scripts/local-api-login-role.sql.
                    'HMS_API_TEST_CONNECTION=Host=db;Port=5432;Database=hms_sql_test;Username=hms_api_login;Password=hms_api_local_only',
                  ]) {
                    sh '''
                      dotnet test backend/Hms.slnx -c Release \
                        --filter "Category=Database" \
                        --logger "trx;LogFilePrefix=db" --results-directory test-results
                    '''
                  }
                }
              }
            }
          }
          post {
            always {
              mstest testResultsFile: 'test-results/**/*.trx', failOnError: false, keepLongStdio: true
            }
            cleanup {
              cleanWs()
            }
          }
        }
      }
    }

    stage('E2E (Playwright)') {
      agent { label 'docker' }
      steps {
        unstash 'api-publish'
        script {
          docker.image(env.POSTGRES_IMAGE).withRun("-e POSTGRES_PASSWORD=${env.PG_PASSWORD}") { pg ->
            docker.image(env.POSTGRES_IMAGE).inside("--link ${pg.id}:db") {
              sh 'until pg_isready -h db -U postgres; do sleep 1; done'
              sh 'DATABASE_URL="postgresql://postgres:${PG_PASSWORD}@db:5432/postgres" SKIP_SQL_TESTS=1 TEST_DB=hms_e2e bash supabase/scripts/run-sql-tests.sh'
            }
            docker.image(env.PLAYWRIGHT_IMAGE).inside("--link ${pg.id}:db --ipc=host") {
              withEnv([
                "npm_config_cache=${env.WORKSPACE}/.npm",
                'E2E_PG_HOST=db',
                "E2E_PG_PASSWORD=${env.PG_PASSWORD}",
                "HMS_MS_PUBLISH=${env.WORKSPACE}/api-publish",
              ]) {
                sh 'npm ci --no-audit --no-fund'
                sh 'npm --prefix apps/web ci --no-audit --no-fund'
                sh 'npx playwright test -c tests/playwright/playwright.config.ts'
              }
            }
          }
        }
      }
      post {
        always {
          junit testResults: 'tests/playwright/test-results/junit.xml', allowEmptyResults: true
          archiveArtifacts artifacts: 'tests/playwright/playwright-report/**, tests/playwright/test-results/**',
                           allowEmptyArchive: true, fingerprint: false
        }
        cleanup {
          cleanWs()
        }
      }
    }
  }
}
