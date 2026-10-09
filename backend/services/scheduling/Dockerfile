# syntax=docker/dockerfile:1
# Scheduling service image (MICROSERVICES-PLAN.md §8). Build context: REPOSITORY ROOT.
#   docker build -f backend/services/scheduling/Dockerfile -t hms-scheduling .
# Only Hms.SharedKernel, Hms.Platform, the Appointments module and this host are copied in, so the image
# build itself proves the service does not depend on another module.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY backend/global.json backend/Directory.Build.props backend/Directory.Packages.props ./
COPY backend/shared/Hms.SharedKernel/Hms.SharedKernel.csproj shared/Hms.SharedKernel/
COPY backend/platform/Hms.Platform/Hms.Platform.csproj platform/Hms.Platform/
COPY backend/modules/Appointments/Hms.Modules.Appointments/Hms.Modules.Appointments.csproj modules/Appointments/Hms.Modules.Appointments/
COPY backend/services/scheduling/Hms.Scheduling.Api/Hms.Scheduling.Api.csproj services/scheduling/Hms.Scheduling.Api/
RUN dotnet restore services/scheduling/Hms.Scheduling.Api/Hms.Scheduling.Api.csproj
COPY backend/shared/Hms.SharedKernel shared/Hms.SharedKernel
COPY backend/platform/Hms.Platform platform/Hms.Platform
COPY backend/modules/Appointments/Hms.Modules.Appointments modules/Appointments/Hms.Modules.Appointments
COPY backend/services/scheduling/Hms.Scheduling.Api services/scheduling/Hms.Scheduling.Api
RUN dotnet publish services/scheduling/Hms.Scheduling.Api/Hms.Scheduling.Api.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY --from=build /app/publish .
# Non-root user shipped with the official .NET images
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Hms.Scheduling.Api.dll"]
