#!/usr/bin/env bash

############################################################################
# Useful for testing whether migration to new version is working properly. #
############################################################################

clean() {
    echo "cleaning..."
    /usr/local/bin/docker-compose -f docker-compose.new-version.yml down --volumes > /dev/null 2> /dev/null
    /usr/local/bin/docker-compose -f docker-compose.stable-version.yml down --volumes > /dev/null 2> /dev/null
    echo "Finished"
}

wait_for_services() {
    # we need to give fixed time for services registration
    sleep 5
    services_list=`curl -s 'http://localhost:8500/v1/catalog/services' | sed -e 's/[{}"]/''/g' | awk -v RS=',' -F: '{print $1}' |  grep -v consul | grep -v reference-ui | paste -sd ","`
    IFS=',' read -r -a services_array <<< "$services_list"

    echo "waiting for ${services_array[*]} to be started up and serving"
    for service in "${services_array[@]}"
    do
        counter=0
        while [[ $counter -lt 25 ]]; do
            let counter=counter+1
            echo "trying $service $counter times"
            service_response=`curl ${BASE_URL}/$service 2> /dev/null`
            if [[ $service_response == {* ]]; then
                break
            fi
            if [[ $counter == 25 ]]; then
                echo "TIMED OUT WAITING FOR SERVICE $service"
                clean
                exit 1
            fi
            if [[ $1 == "test" ]]; then
                test_result=`/usr/local/bin/docker-compose -f docker-compose.new-version.yml exec log sh -c "cat /var/log/messages" | grep ERROR | wc -l`
                if [[ $test_result -ne 0 ]]; then
                    echo '============ LOG ERRORS FROM STARTING NEW CONTAINERS ============'
                    /usr/local/bin/docker-compose -f docker-compose.new-version.yml exec log sh -c "cat /var/log/messages"
                    echo "MIGRATION TESTS FAILURE"
                    #clean
                    exit 1
                fi
            fi
            sleep 5
        done
    done
}

mkdir -p build
cp .env build/
cp -r config build/
cd build

STABLE_VERSION=${STABLE_VERSION:-v3.1.1}
NEW_VERSION=${NEW_VERSION:-master}

echo "DOWNLOADING DOCKER COMPOSE FOR STABLE VERSION $STABLE_VERSION"
curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/${STABLE_VERSION}/docker-compose.yml > docker-compose.stable-version.yml
echo "DOWNLOADING DOCKER COMPOSE FOR NEW VERSION $NEW_VERSION"
curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/${NEW_VERSION}/docker-compose.yml > docker-compose.new-version.yml

clean
/usr/local/bin/docker-compose -f docker-compose.stable-version.yml pull

echo 'STARTING OLD COMPONENT VERSIONS THAT WILL LOAD OLD DEMO DATA TO DATABASE'
/usr/local/bin/docker-compose -f docker-compose.stable-version.yml up --build --force-recreate -d

set -o allexport
source .env
set +o allexport

wait_for_services
echo 'REMOVING OLD CONTAINERS EXCEPT DATABASE'
/usr/local/bin/docker-compose -f docker-compose.stable-version.yml stop > /dev/null 2> /dev/null
docker rm -f `/usr/local/bin/docker-compose -f docker-compose.stable-version.yml ps | awk '{ print $1 }' | grep build | grep -v db | paste -sd " "` > /dev/null 2> /dev/null

echo 'STARTING NEW COMPONENT VERSIONS WITH PRODUCTION FLAG (NO DATA LOSS)'
export spring_profiles_active=production
/usr/local/bin/docker-compose -f docker-compose.new-version.yml up -d

wait_for_services test

echo "MIGRATION TESTS SUCCESS"
clean
exit ${test_result}
