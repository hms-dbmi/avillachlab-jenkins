import groovy.json.JsonSlurper

def fixture = new JsonSlurper().parse(new File(args[0]))
def loader = new GroovyClassLoader(this.class.classLoader)

loader.parseClass('''
package hudson

class AbortException extends RuntimeException {
    AbortException(String message) {
        super(message)
    }
}
''')
loader.parseClass('''
package hudson.model

class ParameterValue {
    Object value
}

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

    static class UserIdCause {
        String userId
    }

    static class RemoteCause {}
}
''')
loader.parseClass('''
package hudson.triggers

class TimerTrigger {
    static class TimerTriggerCause {}
}
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
package jenkins.model

class Jenkins {
    static Object instance
}
''')

def upstreamCauseClass = loader.loadClass('hudson.model.Cause$UpstreamCause')
def userCauseClass = loader.loadClass('hudson.model.Cause$UserIdCause')
def unexpectedCauseClasses = [
    remote: loader.loadClass('hudson.model.Cause$RemoteCause'),
    timer: loader.loadClass('hudson.triggers.TimerTrigger$TimerTriggerCause'),
    replay: loader.loadClass('org.jenkinsci.plugins.workflow.cps.replay.ReplayCause'),
    rebuild: loader.loadClass('com.sonyericsson.rebuild.RebuildCause'),
]
def parametersActionClass = loader.loadClass('hudson.model.ParametersAction')
def abortClass = loader.loadClass('hudson.AbortException')
def jenkinsClass = loader.loadClass('jenkins.model.Jenkins')

def makeCause
makeCause = { data ->
    if (data.type == 'upstream') {
        def cause = upstreamCauseClass.newInstance()
        cause.upstreamProject = data.upstreamProject
        cause.upstreamBuild = data.upstreamBuild as int
        cause.upstreamCauses = (data.upstreamCauses ?: []).collect(makeCause)
        return cause
    }
    if (data.type == 'user') {
        def cause = userCauseClass.newInstance()
        cause.userId = data.userId
        return cause
    }
    return unexpectedCauseClasses[data.type].newInstance()
}

def makeParameters = { values ->
    def action = parametersActionClass.newInstance()
    action.values = values ?: [:]
    return action
}

def makeBuild = { data ->
    if (data == null) {
        return null
    }
    def causes = (data.causes ?: []).collect(makeCause)
    def parameters = makeParameters(data.parameters)
    def build = new Expando()
    build.getAction = { Class ignored -> parameters }
    build.getCauses = { -> causes }
    build.getCause = { Class type -> causes.find { type.isInstance(it) } }
    build.isBuilding = { -> data.building as boolean }
    return build
}

def downstreamBuild = makeBuild(fixture.downstream)
def upstreamBuild = makeBuild(fixture.parent)
def job = new Expando()
job.getBuildByNumber = { int number ->
    fixture.parent != null && fixture.parent.number as int == number ? upstreamBuild : null
}
def jenkins = new Expando()
jenkins.getItemByFullName = { String name ->
    name == 'Deployment Pipeline' || fixture.resolveAnyParentProject ? job : null
}
jenkinsClass.instance = jenkins
Thread.metaClass.getExecutable = { -> downstreamBuild }

try {
    new GroovyShell(loader).evaluate(new File(args[1]))
    println 'ACCEPT'
} catch (Throwable error) {
    if (abortClass.isInstance(error)) {
        println 'REJECT'
    } else {
        error.printStackTrace()
        System.exit(2)
    }
}
