import groovy.json.JsonOutput
import groovy.json.JsonSlurper

class PipelineFailure extends RuntimeException {
    PipelineFailure(String message) { super(message) }
}

def fixture = new JsonSlurper().parse(new File(args[0]))
def workspace = new File(fixture.workspace.toString())
def activeEnvironment = [:]
def reads = []
def writes = [:]
def shellCalls = []
def scheduledBuilds = []

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
def currentBuildValue = new Expando(
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
    new GroovyShell(binding).evaluate(new File(args[1]))
    if (fixture.disruptiveEffect != null) {
        new File(fixture.disruptiveEffect.toString()).text = 'effect'
    }
} catch (PipelineFailure error) {
    status = 'REJECT'
    failure = error.message ?: ''
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
