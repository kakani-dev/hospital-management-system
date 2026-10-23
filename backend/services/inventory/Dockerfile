# syntax=docker/dockerfile:1
# Inventory service image. Build context: REPOSITORY ROOT.
#   docker build -f backend/services/inventory/Dockerfile -t hms-inventory .
# Only Hms.SharedKernel, Hms.Platform, the Inventory module and this host are copied in.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY backend/global.json backend/Directory.Build.props backend/Directory.Packages.props ./
COPY backend/shared/Hms.SharedKernel/Hms.SharedKernel.csproj shared/Hms.SharedKernel/
COPY backend/platform/Hms.Platform/Hms.Platform.csproj platform/Hms.Platform/
COPY backend/modules/Inventory/Hms.Modules.Inventory/Hms.Modules.Inventory.csproj modules/Inventory/Hms.Modules.Inventory/
COPY backend/services/inventory/Hms.Inventory.Api/Hms.Inventory.Api.csproj services/inventory/Hms.Inventory.Api/
RUN dotnet restore services/inventory/Hms.Inventory.Api/Hms.Inventory.Api.csproj
COPY backend/shared/Hms.SharedKernel shared/Hms.SharedKernel
COPY backend/platform/Hms.Platform platform/Hms.Platform
COPY backend/modules/Inventory/Hms.Modules.Inventory modules/Inventory/Hms.Modules.Inventory
COPY backend/services/inventory/Hms.Inventory.Api services/inventory/Hms.Inventory.Api
RUN dotnet publish services/inventory/Hms.Inventory.Api/Hms.Inventory.Api.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY --from=build /app/publish .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Hms.Inventory.Api.dll"]
