#!/usr/local/bin/groovy

def containers = args[1].split(',')
println "waiting for " + containers + " to be started up and serving"

for (container in containers) {
    if (!isReachable(container)) {
        System.exit(1)
    }
}

private boolean isReachable(container) {
    def response = ""
    try {
        response = new URL(args[0]+"/"+container).text
        println response
    } catch (Exception e) {
        println "request failed"
    }

    if (response != "") {
        return true;
    }

    return false;
}

