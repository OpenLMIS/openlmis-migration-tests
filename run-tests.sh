#!/usr/bin/env bash

############################################################################
# Useful for testing whether migration to new version is working properly. #
############################################################################

clean() {
    /usr/local/bin/docker-compose -f docker-compose.new-version.yml down --volumes
    /usr/local/bin/docker-compose -f docker-compose.stable-version.yml down --volumes
    rm docker-compose.stable-version.yml
    rm docker-compose.new-version.yml
}

removeService() {
    /usr/local/bin/docker-compose -f docker-compose.stable-version.yml kill $1 &&
    /usr/local/bin/docker-compose -f docker-compose.stable-version.yml rm -f $1
}

checkContainers() {
    groovy ../wait_for_containers.groovy $1 $2
    if [[ $? -eq 0 ]]; then
        break
    fi

    if [[ $3 -eq 50 ]]; then
        echo "TIMED OUT WAITING FOR CONTAINER"
        clean
        exit 1
    fi

    sleep 5
}

mkdir -p build
cp .env build/
cp -r config build/
cd build
echo 'DOWNLOADING DOCKER COMPOSE FOR STABLE VERSION'
curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/${STABLE_VERSION:-v3.1.1}/docker-compose.yml > docker-compose.stable-version.yml
echo 'DOWNLOADING DOCKER COMPOSE FOR NEW VERSION'
curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/${NEW_VERSION:-master}/docker-compose.yml > docker-compose.new-version.yml

/usr/local/bin/docker-compose -f docker-compose.stable-version.yml down --volumes
/usr/local/bin/docker-compose -f docker-compose.new-version.yml down --volumes

/usr/local/bin/docker-compose -f docker-compose.stable-version.yml pull

echo 'STARTING OLD COMPONENT VERSIONS THAT WILL LOAD OLD DEMO DATA TO DATABASE'
/usr/local/bin/docker-compose -f docker-compose.stable-version.yml up --build --force-recreate -d

set -o allexport
source .env
set +o allexport

# we need to give fixed time for services registration
sleep 5
services_list=`curl -s 'http://localhost:8500/v1/catalog/services' | sed -e 's/[{}"]/''/g' | awk -v RS=',' -F: '{print $1}' |  grep -v consul | grep -v reference-ui | paste -sd ","`

counter=0
while [[ $counter -lt 50 ]]; do
    let counter=counter+1
    checkContainers ${BASE_URL} $services_list $counter
done

/usr/local/bin/docker-compose -f docker-compose.stable-version.yml stop

docker rm -f `/usr/local/bin/docker-compose -f docker-compose.stable-version.yml ps | awk '{ print $1 }' | grep build | grep -v db | paste -sd " "`

echo 'STARTING NEW COMPONENT VERSIONS WITH PRODUCTION FLAG (NO DATA LOSS)'
export spring_profiles_active=production
/usr/local/bin/docker-compose -f docker-compose.new-version.yml up -d

counter=0
test_result=1
while [[ $counter -lt 50 ]]; do
    test_result=`/usr/local/bin/docker-compose -f docker-compose.new-version.yml exec log sh -c "cat /var/log/messages" | grep ERROR | wc -l`
    if [[ $test_result -ne 0 ]]; then
        break
    fi
    let counter=counter+1
    checkContainers ${BASE_URL} $services_list $counter
done

echo '============ LOG ERRORS FROM STARTING NEW CONTAINERS ============'
/usr/local/bin/docker-compose -f docker-compose.new-version.yml exec log sh -c "cat /var/log/messages"

clean

exit ${test_result}
