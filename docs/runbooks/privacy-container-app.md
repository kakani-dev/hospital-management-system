# Create ca-hms-privacy once

Do this before a merge that puts privacy in the deploy order reaches `main`. Live tags fail closed when any app in that order is missing, and the rollout does not create apps. This runbook does not create the app for you.

Same place as the other API apps: resource group `rg-medicore-hms-dev`, environment `cae-medicore-hms-dev` (Consumption, Central India), registry `acrmedicorehmsdev.azurecr.io`. No new environment, no workload profile, no Key Vault, no GitHub secret.

1. Build and push one image so the app has a tag to pull. The pipeline later replaces it with `hms-privacy:sha-<40 hex>`.

   ```bash
   docker build -f backend/services/privacy/Dockerfile -t acrmedicorehmsdev.azurecr.io/hms-privacy:bootstrap .
   az acr login -n acrmedicorehmsdev
   docker push acrmedicorehmsdev.azurecr.io/hms-privacy:bootstrap
   ```

2. Create the Container App on the existing environment. Internal ingress, target port 8080, Consumption size matching the other services (0.25 CPU, 0.5Gi, min 0, max 1). HTTP probes: startup and liveness `/health/live`, readiness `/health/ready`.

   ```bash
   az containerapp create -g rg-medicore-hms-dev -n ca-hms-privacy \
     --environment cae-medicore-hms-dev \
     --image acrmedicorehmsdev.azurecr.io/hms-privacy:bootstrap \
     --ingress internal --target-port 8080 --transport auto --allow-insecure \
     --cpu 0.25 --memory 0.5Gi --min-replicas 0 --max-replicas 1 \
     --registry-server acrmedicorehmsdev.azurecr.io
   ```

   Give it an identity with AcrPull, the same way `scripts/azure-oidc-setup.sh` does for an app that does not yet pull from the registry. Re-running that script after the app exists is enough; it does not create a second app.

3. On the hosted database, out of band, create the login. Do not put the password in git.

   ```sql
   create role hms_privacy_login login noinherit password '<generated>';
   grant hms_svc_privacy to hms_privacy_login;
   ```

4. Set the ACA secret `hms-db` on `ca-hms-privacy` only, to the Npgsql connection string for that login (pool, `No Reset On Close=true`, same shape as the other services). Set `ConnectionStrings__HmsDatabase=secretref:hms-db` and `Database__SessionRole=hms_svc_privacy`. Also set `hms-edge-key` to the same edge key the other apps already use. The workflow never writes `hms-db`.

5. Leave the cluster address to the edge rollout. It sets `ReverseProxy__Clusters__privacy__Destinations__primary__Address=http://ca-hms-privacy/` on every edge revision. Do not hand-edit that revision.
