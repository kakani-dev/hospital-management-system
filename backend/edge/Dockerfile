# syntax=docker/dockerfile:1
# Edge (YARP gateway) image: the single public base URL in front of identity / patients / scheduling
# (docs/architecture/microservices.md). Build context: REPOSITORY ROOT.
#   docker build -f backend/edge/Dockerfile -t hms-edge .
# Only Hms.SharedKernel, Hms.Platform and the edge host are copied in: the edge never hosts a module.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY backend/global.json backend/Directory.Build.props backend/Directory.Packages.props ./
COPY backend/shared/Hms.SharedKernel/Hms.SharedKernel.csproj shared/Hms.SharedKernel/
COPY backend/platform/Hms.Platform/Hms.Platform.csproj platform/Hms.Platform/
COPY backend/edge/Hms.Edge/Hms.Edge.csproj edge/Hms.Edge/
RUN dotnet restore edge/Hms.Edge/Hms.Edge.csproj
COPY backend/shared/Hms.SharedKernel shared/Hms.SharedKernel
COPY backend/platform/Hms.Platform platform/Hms.Platform
COPY backend/edge/Hms.Edge edge/Hms.Edge
RUN dotnet publish edge/Hms.Edge/Hms.Edge.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY --from=build /app/publish .
# Non-root user shipped with the official .NET images
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Hms.Edge.dll"]
