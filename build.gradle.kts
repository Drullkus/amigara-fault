// Written by Claude Code; conversation transcript:
// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
plugins {
    application
}

group = "dev.drullkus"
version = "0.1.0"

repositories {
    mavenCentral()
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(25)
    }
}

dependencies {
    implementation("org.jspecify:jspecify:1.0.0")
}

application {
    // The depth stream demo is the only entry point for now. Point this at the wall renderer later.
    mainClass = "dev.drullkus.amigara.depth.DepthStreamDemo"
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    options.compilerArgs.add("-Xlint:all")
}
