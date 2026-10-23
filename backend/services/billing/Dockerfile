# syntax=docker/dockerfile:1
# Billing service image. Build context: REPOSITORY ROOT.
#   docker build -f backend/services/billing/Dockerfile -t hms-billing .
# Only Hms.SharedKernel, Hms.Platform, the Billing module and this host are copied in.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY backend/global.json backend/Directory.Build.props backend/Directory.Packages.props ./
COPY backend/shared/Hms.SharedKernel/Hms.SharedKernel.csproj shared/Hms.SharedKernel/
COPY backend/platform/Hms.Platform/Hms.Platform.csproj platform/Hms.Platform/
COPY backend/modules/Billing/Hms.Modules.Billing/Hms.Modules.Billing.csproj modules/Billing/Hms.Modules.Billing/
COPY backend/services/billing/Hms.Billing.Api/Hms.Billing.Api.csproj services/billing/Hms.Billing.Api/
RUN dotnet restore services/billing/Hms.Billing.Api/Hms.Billing.Api.csproj
COPY backend/shared/Hms.SharedKernel shared/Hms.SharedKernel
COPY backend/platform/Hms.Platform platform/Hms.Platform
COPY backend/modules/Billing/Hms.Modules.Billing modules/Billing/Hms.Modules.Billing
COPY backend/services/billing/Hms.Billing.Api services/billing/Hms.Billing.Api
RUN dotnet publish services/billing/Hms.Billing.Api/Hms.Billing.Api.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY --from=build /app/publish .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Hms.Billing.Api.dll"]
