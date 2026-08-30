import groovy.json.JsonOutput
import groovy.json.JsonSlurper

class PipelineFailure extends RuntimeException {
    PipelineFailure(String message) { super(message) }
}

def fixture = new JsonSlurper().parse(new File(args[0]))
def loader = new GroovyClassLoader(this.class.classLoader)

loader.parseClass('''
package com.cloudbees.groovy.cps

import java.lang.annotation.ElementType
import java.lang.annotation.Retention
import java.lang.annotation.RetentionPolicy
import java.lang.annotation.Target

@Retention(RetentionPolicy.RUNTIME)
@Target([ElementType.METHOD])
@interface NonCPS {}
''')
loader.parseClass('''
package hudson

class AbortException extends RuntimeException {
    AbortException(String message) { super(message) }
}
''')
loader.parseClass('''
package hudson.model

class ParameterValue { Object value }

class ParametersAction {
    Map values
    ParameterValue getParameter(String name) {
        values.containsKey(name) ? new ParameterValue(value: values[name]) : null
    }
}

class Cause {
    static class UpstreamCause {
        String upstreamProject
        int upstreamBuild
        List upstreamCauses
    }
    static class UserIdCause { String userId }
    static class RemoteCause {}
}
''')
loader.parseClass('''
package hudson.triggers
class TimerTrigger { static class TimerTriggerCause {} }
''')
loader.parseClass('''
package org.jenkinsci.plugins.workflow.cps.replay
class ReplayCause {}
''')
loader.parseClass('''
package com.sonyericsson.rebuild
class RebuildCause {}
''')
loader.parseClass('''
package synthetic
class OtherCause {}
''')
loader.parseClass('''
package jenkins.model
class Jenkins { static Object instance }
''')

def upstreamCauseClass = loader.loadClass('hudson.model.Cause$UpstreamCause')
def userCauseClass = loader.loadClass('hudson.model.Cause$UserIdCause')
def causeClasses = [
    remote: loader.loadClass('hudson.model.Cause$RemoteCause'),
    timer: loader.loadClass('hudson.triggers.TimerTrigger$TimerTriggerCause'),
    replay: loader.loadClass('org.jenkinsci.plugins.workflow.cps.replay.ReplayCause'),
    rebuild: loader.loadClass('com.sonyericsson.rebuild.RebuildCause'),
    other: loader.loadClass('synthetic.OtherCause'),
]
def parametersActionClass = loader.loadClass('hudson.model.ParametersAction')
def abortClass = loader.loadClass('hudson.AbortException')
def jenkinsClass = loader.loadClass('jenkins.model.Jenkins')
def workspace = new File(fixture.workspace.toString())
def activeEnvironment = [:]
def reads = []
def writes = [:]
def shellCalls = []
def scheduledBuilds = []

def causeType = { data ->
    if (data.type) return data.type.toString()
    def className = data.get('className')?.toString()
    if (className == 'hudson.model.Cause$UpstreamCause') return 'upstream'
    if (className == 'hudson.model.Cause$UserIdCause') return 'user'
    if (className?.contains('ReplayCause')) return 'replay'
    if (className?.contains('RebuildCause')) return 'rebuild'
    if (className?.contains('RemoteCause')) return 'remote'
    if (className?.contains('TimerTriggerCause')) return 'timer'
    return 'other'
}
def makeCause
makeCause = { data ->
    def type = causeType(data)
    if (type == 'upstream') {
        def cause = upstreamCauseClass.newInstance()
        cause.upstreamProject = data.upstreamProject
        cause.upstreamBuild = (data.upstreamBuild ?: 41) as int
        cause.upstreamCauses = (data.upstreamCauses ?: []).collect(makeCause)
        return cause
    }
    if (type == 'user') {
        def cause = userCauseClass.newInstance()
        cause.userId = data.userId
        return cause
    }
    causeClasses[type].newInstance()
}
def makeParameters = { values ->
    def action = parametersActionClass.newInstance()
    action.values = values ?: [:]
    action
}
def makeBuild = { data ->
    if (data == null) return null
    def rawCauses = (data.causes ?: []).collect(makeCause)
    def action = makeParameters(data.parameters)
    def build = new Expando(number: (data.number ?: 1) as int)
    build.getAction = { Class ignored -> action }
    build.getCauses = { -> rawCauses }
    build.getCause = { Class type -> rawCauses.find { type.isInstance(it) } }
    build.isBuilding = { -> data.building == null ? true : data.building as boolean }
    build
}

def pipelineError = { String message -> throw new PipelineFailure(message) }
def fileExistsStep = { String path -> new File(path).exists() }
def readFileStep = { String path ->
    reads << path
    def file = new File(path)
    def value = file.text
    if (path == fixture.runtimePath && fixture.runtimeReplacement != null) {
        file.text = fixture.runtimeReplacement.toString()
    }
    value
}
def writeFileStep = { Map values ->
    writes[values.file.toString()] = values.text.toString()
    new File(workspace, values.file.toString()).text = values.text.toString()
}
def withEnvStep = { List values, Closure body ->
    def saved = new LinkedHashMap(activeEnvironment)
    values.each { value ->
        def separator = value.toString().indexOf('=')
        activeEnvironment[value.toString().substring(0, separator)] =
            value.toString().substring(separator + 1)
    }
    try {
        body()
    } finally {
        activeEnvironment.clear()
        activeEnvironment.putAll(saved)
    }
}
def shStep = { Object input ->
    def options = input instanceof Map ? input : [script: input.toString(), returnStdout: false]
    def source = options.script.toString()
    shellCalls << [script: source, environment: new LinkedHashMap(activeEnvironment)]
    def environment = new LinkedHashMap(System.getenv())
    environment.putAll(activeEnvironment)
    def envList = environment.collect { key, value -> "${key}=${value}" }
    def process = ['bash', '-c', source].execute(envList, workspace)
    def stdout = new StringBuffer()
    def stderr = new StringBuffer()
    process.consumeProcessOutput(stdout, stderr)
    def status = process.waitFor()
    if (status != 0) {
        throw new PipelineFailure(stderr.toString() ?: stdout.toString())
    }
    options.returnStdout ? stdout.toString() : status
}

def causes = (fixture.causes ?: []).collect { cause ->
    def className = cause.get('className')?.toString()
    if (!className && cause.containsKey('userId')) {
        className = 'hudson.model.Cause$UserIdCause'
    } else if (!className && cause.containsKey('upstreamProject')) {
        className = 'hudson.model.Cause$UpstreamCause'
    }
    [className: className, value: new Expando(cause as Map)]
}
def downstreamBuild = makeBuild([
    number: fixture.buildNumber ?: 1,
    building: true,
    causes: fixture.causes ?: [],
    parameters: fixture.params ?: [:],
])
def upstreamBuild = makeBuild(fixture.parent)
def lastParentBuild = fixture.parent == null ? null : new Expando(
    number: (fixture.lastParentBuildNumber ?: fixture.parent.number) as int
)
def parentJob = new Expando()
parentJob.getBuildByNumber = { int number ->
    fixture.parent != null && fixture.parent.number as int == number ? upstreamBuild : null
}
parentJob.getLastBuild = { -> lastParentBuild }
def jenkins = new Expando()
jenkins.getItemByFullName = { String name ->
    name == 'Deployment Pipeline' || fixture.resolveAnyParentProject ? parentJob : null
}
jenkinsClass.instance = jenkins
def currentBuildValue = new Expando(
    rawBuild: downstreamBuild,
    getBuildCauses: { Object... requested ->
        def requestedClass = requested.length ? requested[0]?.toString() : null
        def matching = requestedClass ? causes.findAll { it.className == requestedClass } : causes
        matching.collect { it.value }
    }
)
def buildStep = { Map values ->
    scheduledBuilds << [
        job: values.job?.toString(),
        parameters: (values.parameters ?: []).collect { parameter ->
            [name: parameter.name?.toString(), value: parameter.value]
        },
    ]
    new Expando(number: 1)
}
def paramsValue = new Expando(fixture.params as Map)
def envValues = new LinkedHashMap(fixture.env as Map)
envValues.JENKINS_HOME = fixture.jenkinsHome.toString()
def envValue = new Expando(envValues)
def bindingValues = [
    params: paramsValue,
    env: envValue,
    currentBuild: currentBuildValue,
    JENKINS_HOME: fixture.jenkinsHome.toString(),
    RELEASE_CONTROL_BRANCH: fixture.releaseControlBranch ?: 'synthetic-release-control',
    error: pipelineError,
    fileExists: fileExistsStep,
    readFile: readFileStep,
    writeFile: writeFileStep,
    withEnv: withEnvStep,
    sh: shStep,
    build: buildStep,
    banner_rollout_present: fixture.bannerRolloutPresent,
    banner_deployment: fixture.bannerDeployment,
    banner_tuple_sha256: fixture.bannerTupleSha256,
    release_control_commit: fixture.releaseControlCommit,
    aim_attestation_json: '',
    banner_forward: false,
    bannerRolloutPresent: fixture.bannerRolloutPresent,
    bannerDeployment: fixture.bannerDeployment,
    pipelineBuildId: fixture.releaseControlCommit,
    bannerRolloutTupleSha: '',
]
def binding = new Binding(bindingValues)
def status = 'ACCEPT'
def failure = ''
try {
    new GroovyShell(loader, binding).evaluate(new File(args[1]))
    if (fixture.disruptiveEffect != null) {
        new File(fixture.disruptiveEffect.toString()).text = 'effect'
    }
} catch (Throwable error) {
    if (error instanceof PipelineFailure || abortClass.isInstance(error)) {
        status = 'REJECT'
        failure = error.message ?: ''
    } else {
        throw error
    }
}

println JsonOutput.toJson([
    status: status,
    failure: failure,
    reads: reads,
    writes: writes,
    shellCalls: shellCalls,
    scheduledBuilds: scheduledBuilds,
    propagatedAttestation: binding.getVariable('aim_attestation_json'),
    tupleSha256: binding.getVariable('bannerRolloutTupleSha'),
])
