# syntax=docker/dockerfile:1
# ASP.NET Core gateway (modular monolith). Build context: repository root.
#   docker build -f infra/docker/api.Dockerfile -t hms-api .
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY backend/global.json backend/Directory.Build.props backend/Directory.Packages.props backend/Hms.slnx ./
COPY backend/shared/Hms.SharedKernel/Hms.SharedKernel.csproj shared/Hms.SharedKernel/
COPY backend/modules/Identity/Hms.Modules.Identity/Hms.Modules.Identity.csproj modules/Identity/Hms.Modules.Identity/
COPY backend/modules/Patients/Hms.Modules.Patients/Hms.Modules.Patients.csproj modules/Patients/Hms.Modules.Patients/
COPY backend/gateway/Hms.Gateway/Hms.Gateway.csproj gateway/Hms.Gateway/
RUN dotnet restore gateway/Hms.Gateway/Hms.Gateway.csproj
COPY backend/shared shared
COPY backend/modules modules
COPY backend/gateway gateway
RUN dotnet publish gateway/Hms.Gateway/Hms.Gateway.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY --from=build /app/publish .
# Non-root user shipped with the official .NET images
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Hms.Gateway.dll"]
