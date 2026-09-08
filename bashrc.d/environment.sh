#!/usr/bin/env bash

JMETER_PATH=/c/Users/alexander.osterwald/sources/dfv/development/test-automation/dfv_services_qa/3rdParty/apache-jmeter-5.4.3/bin
export JMETER_PATH

export PATH="/c/Program Files/Microsoft/jdk-21.0.5.11-hotspot/bin:$JMETER_PATH:$PATH"
export ANDROID_HOME="/c/Users/alexander.osterwald/.jdks/android-sdks"
export MAVEN_OPTS="-Djavax.net.ssl.keyStore=$HOME/.m2/cacerts -Djavax.net.ssl.keyStorePassword=changeit -Djavax.net.ssl.trustStore=$HOME/.m2/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
