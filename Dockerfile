# Builds and runs the Java depth receiver. The Swift sidecar cannot run here: it needs the Mac's
# webcam, Vision and Core ML. Run the sidecar on the host and point it at localhost:47011.
# Written by Claude Code; conversation transcript:
# llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md

FROM eclipse-temurin:25-jdk AS build
WORKDIR /src
COPY gradlew settings.gradle.kts build.gradle.kts gradle.properties ./
COPY gradle gradle
# Fetch the Gradle distribution first so source edits do not repeat the download.
RUN ./gradlew --no-daemon --version
COPY src src
RUN ./gradlew --no-daemon installDist

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /src/build/install/amigara-fault /app
EXPOSE 47011
ENTRYPOINT ["/app/bin/amigara-fault"]
