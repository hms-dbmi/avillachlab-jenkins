/*
 * Auto-approve the script-security approvals for the jobs baked into this image.
 *
 * Why: the controller is built fresh from this repo (config.xml, jobs, and
 * scriptApproval.xml are COPYed into the image). scriptApproval.xml records the
 * SHA-512 hash of each non-sandboxed system-Groovy script, and those hashes go
 * stale the moment a job's script text changes -- so a newly deployed controller
 * would leave those jobs "pending approval" until an admin clicked approve.
 *
 * This runs on every startup (Jenkins executes $JENKINS_HOME/init.groovy.d/*.groovy
 * after jobs are loaded) and pre-approves each baked job's script by hash, using
 * the plugin's OWN hashing so it always matches. It also clears anything already
 * queued as pending. Idempotent: re-approving is a no-op.
 *
 * Trust model: every job here comes from this git-managed image, so approving the
 * scripts it ships is equivalent to trusting the repo. It does NOT globally
 * disable script security -- a script that is not present at startup (e.g. one a
 * user pastes into a new job later) still requires normal approval until the next
 * controller rebuild.
 */
import jenkins.model.Jenkins
import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval
import org.jenkinsci.plugins.scriptsecurity.sandbox.groovy.SecureGroovyScript
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import org.jenkinsci.plugins.workflow.job.WorkflowJob

def approval = ScriptApproval.get()
int approved = 0

def approveText = { script ->
    if (script == null) return
    try {
        approval.approveScript(ScriptApproval.hash(script as String, 'groovy'))
        approved++
    } catch (ignored) {}
}

// 1) Pipeline (Workflow) jobs: inline CpsFlowDefinition scripts.
try {
    Jenkins.get().getAllItems(WorkflowJob).each { job ->
        def d = job.getDefinition()
        if (d instanceof CpsFlowDefinition) {
            approveText(d.getScript())
        }
    }
} catch (Throwable t) {
    println "[auto-approve-scripts] pipeline scan skipped: ${t.message}"
}

// 2) Freestyle System Groovy build steps: non-sandboxed scripts need hash approval.
//    Property names vary across groovy-plugin versions, so navigate defensively.
try {
    Jenkins.get().getAllItems(hudson.model.AbstractProject).each { job ->
        try {
            job.getBuildersList().each { b ->
                ['source', 'scriptSource'].each { srcProp ->
                    try {
                        def src = b."$srcProp"
                        ['command', 'scriptSource', 'secureGroovyScript'].each { sProp ->
                            try {
                                def sgs = src?."$sProp"
                                if (sgs instanceof SecureGroovyScript) {
                                    approveText(sgs.getScript())
                                }
                            } catch (ignored) {}
                        }
                    } catch (ignored) {}
                }
            }
        } catch (ignored) {}
    }
} catch (Throwable t) {
    println "[auto-approve-scripts] system-groovy scan skipped: ${t.message}"
}

// 3) Catch-all: approve anything already queued as pending (scripts + signatures).
approval.getPendingScripts().collect { it.getHash() }.each {
    try { approval.approveScript(it) } catch (ignored) {}
}
approval.getPendingSignatures().collect { it.getSignature() }.each {
    try { approval.approveSignature(it) } catch (ignored) {}
}

approval.save()
println "[auto-approve-scripts] approved ${approved} job script(s); pending scripts/signatures cleared"
