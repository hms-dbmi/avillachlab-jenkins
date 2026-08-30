def loader = new GroovyClassLoader(this.class.classLoader)

loader.parseClass('''
package hudson

class AbortException extends RuntimeException {
    AbortException(String message) { super(message) }
}
''')
loader.parseClass('''
package hudson.model

class StringParameterValue {
    String name
    String value
    StringParameterValue(String name, String value) { this.name = name; this.value = value }
}

class BooleanParameterValue {
    String name
    boolean value
    BooleanParameterValue(String name, boolean value) { this.name = name; this.value = value }
}

class ParametersAction {
    List values
    ParametersAction(List values) { this.values = values }
}

class Result {
    static final String SUCCESS = 'SUCCESS'
}
''')
loader.parseClass('''
package jenkins.model

class Jenkins {
    static Object instance
}
''')

def waited = false
def childResult = args[2]
def future = new Expando()
future.get = {
    waited = true
    def run = new Expando()
    run.getResult = { -> childResult }
    run
}
def job = new Expando()
job.scheduleBuild2 = { Object... ignored -> future }
loader.loadClass('jenkins.model.Jenkins').instance = new Expando(
    getItemByFullName: { String ignored -> job }
)

def bannerRollout = args[1].toBoolean()
def binding = new Binding([
    bannerRollout: bannerRollout,
    buildSpec: bannerRollout
        ? [banner_rollout: [deployment: 'BDC', tupleSha256: 'a' * 64]]
        : [banner_rollout: null],
    envVars: [GIT_COMMIT: 'b' * 40, stack_s3_bucket: 'synthetic-bucket'],
    dataset_s3_object_key: 'dataset',
    destigmatized_dataset_s3_object_key: 'destigmatized',
    genomic_s3_object_key: 'genomic',
])

try {
    new GroovyShell(loader, binding).evaluate(new File(args[0]))
    println waited ? 'WAITED' : 'NOT_WAITED'
} catch (Throwable error) {
    if (loader.loadClass('hudson.AbortException').isInstance(error)) {
        println waited ? 'REJECT_WAITED' : 'REJECT_NOT_WAITED'
    } else {
        error.printStackTrace()
        System.exit(2)
    }
}
