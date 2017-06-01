#!/usr/local/bin/groovy

def containers = args[0].split(',')
println "waiting for " + containers + " to be started up and serving"

for (container in containers) {
    if (!isReachable(container)) {
        System.exit(1)
    }
}

private boolean isReachable(container) {
    boolean isRequestSuccessFul = false

    for (def i = 0; i < 50; i++) {
        println("trying $container ${i + 1} times")

        def response = ""
        try {
            response = new URL(container).text
            println response
        } catch (Exception e) {
            println "request failed"
        }

        if (response != "") {
            isRequestSuccessFul = true;
            break
        } else {
            sleep(5000)
        }
    }

    return isRequestSuccessFul
}

