// Runs the pipeline script of the job "HPDS Data - Deploy to Staging Stack" against a fake pipeline DSL and prints a trace.
// usage: groovy deploy-staging.harness.groovy <pipeline script file>
// The scenario comes from the environment:
//   SCEN_AUTH, SCEN_OPEN, SCEN_GENOMIC   the three job parameters
//   SCEN_STACKS                          the text of the stacks.json that the fake Retrieve Deployment State archived
//   SCEN_FAIL_JOBS                       comma separated job names whose build fails
//   SCEN_SH_FAIL                         when set, the sh step (the staged-data check) fails
//   SCEN_INTERRUPT_AT_SH                 when set, the sh step throws an InterruptedException (abort or timeout)
// Output: one "T: ..." line per step, then "RESULT: ok" (exit 0) or "RESULT: failed: <message>" (exit 1).
// No Jenkins, no AWS: every step is a closure that only records itself.
def env = System.getenv()
def trace = { Object s -> println "T: " + s.toString() }
def failJobs = (env.SCEN_FAIL_JOBS ?: '').split(',').findAll { it } as Set
int buildNumber = 100

def binding = new Binding()
binding.setVariable('params', [
    DATA_S3_OBJECT_KEY                 : env.SCEN_AUTH ?: '',
    DESTIGMATIZED_DATASET_S3_OBJECT_KEY: env.SCEN_OPEN ?: '',
    GENOMIC_DATASET_S3_OBJECT_KEY      : env.SCEN_GENOMIC ?: '',
])
binding.setVariable('error', { Object m -> throw new RuntimeException('error: ' + m.toString()) })
binding.setVariable('echo', { Object m -> trace('echo ' + m) })
binding.setVariable('build', { Map m ->
    def ps = (m.parameters ?: []).collect { it.name + '=' + it.value }.join(',')
    trace('build ' + m.job + (ps ? ' ' + ps : ''))
    if (failJobs.contains(m.job)) {
        throw new RuntimeException('job failed: ' + m.job)
    }
    return [number: ++buildNumber]
})
binding.setVariable('lock', { Object name, Closure c ->
    trace('lock ' + name + ' enter')
    try { c() } finally { trace('lock ' + name + ' exit') }
})
binding.setVariable('timeout', { Map m, Closure c ->
    trace('timeout ' + m.time + ' ' + m.unit)
    c()
})
binding.setVariable('stage', { Object name, Closure c ->
    trace('stage ' + name)
    c()
})
binding.setVariable('node', { Closure c ->
    trace('node')
    c()
})
binding.setVariable('withEnv', { List l, Closure c ->
    trace('withEnv ' + l.collect { it.toString() }.join(' '))
    c()
})
binding.setVariable('sh', { Object s ->
    trace('sh')
    if (env.SCEN_INTERRUPT_AT_SH) {
        throw new InterruptedException('interrupted')
    }
    if (env.SCEN_SH_FAIL) {
        throw new RuntimeException('sh failed')
    }
})
binding.setVariable('copyArtifacts', { Map m -> trace('copyArtifacts ' + m.projectName + ' ' + m.filter + ' ' + m.selector) })
binding.setVariable('specific', { Object s -> 'specific:' + s })
binding.setVariable('readFile', { Object f ->
    trace('readFile ' + f)
    return env.SCEN_STACKS ?: ''
})

try {
    new GroovyShell(binding).evaluate(new File(args[0]))
    println 'RESULT: ok'
} catch (Throwable t) {
    println 'RESULT: failed: ' + t.message
    System.exit(1)
}
