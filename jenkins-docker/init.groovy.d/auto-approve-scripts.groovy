/*
 * Auto-approve the script-security approvals for the jobs baked into this image.
 *
 * Why: the controller is built fresh from this repo (config.xml, jobs, and
 * scriptApproval.xml are COPYed into the image). scriptApproval.xml records the
 * SHA-512 hash of each non-sandboxed system-Groovy script, and those hashes go
 * stale the moment a job's script text changes, so a newly deployed controller
 * would leave those jobs "pending approval" until an admin clicked approve.
 *
 * This runs on every startup (Jenkins executes $JENKINS_HOME/init.groovy.d/*.groovy
 * after jobs are loaded) and pre-approves each baked job's script by hash, using
 * the plugin's OWN hashing so it always matches. Idempotent: re-approving is a
 * no-op.
 *
 * Section 3 is wider than the other two and needs reading before you touch it. It
 * approves everything already queued as pending, signatures as well as scripts,
 * and "pending" means whatever accumulated in $JENKINS_HOME/scriptApproval.xml
 * since the container was created. Requests filed by ordinary user activity land
 * in that same queue, so section 3 is not limited to content this repo ships.
 * That file sits in the container's writable layer, since /var/jenkins_home/workspace
 * is the only part of JENKINS_HOME that is mounted, so a restart preserves the
 * queue and a container recreate resets it to the baked file.
 *
 * The signature half of section 3 is load-bearing. The baked scriptApproval.xml
 * was last updated in 2024 and lacks signatures the sandboxed Build and Deploy
 * pipelines need: they call new JsonSlurper().parseText, while the baked list
 * carries only the JsonSlurperClassic equivalents. Dropping that loop breaks
 * those jobs on a fresh controller. It is also a poor mechanism, because a
 * signature goes pending only after a script has already failed with
 * RejectedAccessException, so the loop clears the failure on the NEXT startup
 * rather than preventing it. Baking the missing signatures into
 * scriptApproval.xml would fix the first run and let the signature loop go.
 *
 * Trust model: approving the scripts this image ships is equivalent to trusting
 * the repo. Note it is not the privilege boundary on this controller either way,
 * which runs AuthorizationStrategy$Unsecured with SecurityRealm$None, so every
 * visitor already holds Overall/Administer and script console access.
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
                        // 'script' is the shape this repo's jobs use
                        // (StringSystemScriptSource.script); the rest cover other
                        // groovy-plugin versions.
                        ['script', 'command', 'scriptSource', 'secureGroovyScript'].each { sProp ->
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
