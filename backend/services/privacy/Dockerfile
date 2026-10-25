# syntax=docker/dockerfile:1
# Privacy service image. Build context: REPOSITORY ROOT.
#   docker build -f backend/services/privacy/Dockerfile -t hms-privacy .
# Only Hms.SharedKernel, Hms.Platform, the Privacy module and this host are copied in.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY backend/global.json backend/Directory.Build.props backend/Directory.Packages.props ./
COPY backend/shared/Hms.SharedKernel/Hms.SharedKernel.csproj shared/Hms.SharedKernel/
COPY backend/platform/Hms.Platform/Hms.Platform.csproj platform/Hms.Platform/
COPY backend/modules/Privacy/Hms.Modules.Privacy/Hms.Modules.Privacy.csproj modules/Privacy/Hms.Modules.Privacy/
COPY backend/services/privacy/Hms.Privacy.Api/Hms.Privacy.Api.csproj services/privacy/Hms.Privacy.Api/
RUN dotnet restore services/privacy/Hms.Privacy.Api/Hms.Privacy.Api.csproj
COPY backend/shared/Hms.SharedKernel shared/Hms.SharedKernel
COPY backend/platform/Hms.Platform platform/Hms.Platform
COPY backend/modules/Privacy/Hms.Modules.Privacy modules/Privacy/Hms.Modules.Privacy
COPY backend/services/privacy/Hms.Privacy.Api services/privacy/Hms.Privacy.Api
RUN dotnet publish services/privacy/Hms.Privacy.Api/Hms.Privacy.Api.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY --from=build /app/publish .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Hms.Privacy.Api.dll"]
