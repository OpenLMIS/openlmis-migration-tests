#!/usr/bin/env bash

############################################################################
# Useful for testing whether migration to new version is working properly. #
############################################################################

clean() {
    /usr/local/bin/docker-compose -f docker-compose.stable-version.yml down --volumes
    /usr/local/bin/docker-compose -f docker-compose.new-version.yml down --volumes
    rm docker-compose.stable-version.yml
    rm docker-compose.new-version.yml
}

returnIfErrors() {
    errorCode=$?
    if [[ !( "$errorCode" == 0 ) ]] ; then
        echo 'TIMED OUT WAITING FOR CONTAINER'
        clean
        exit $errorCode
    fi
}

removeService() {
    /usr/local/bin/docker-compose -f docker-compose.stable-version.yml kill $1 &&
    /usr/local/bin/docker-compose -f docker-compose.stable-version.yml rm -f $1
}

echo 'DOWNLOADING DOCKER COMPOSE FOR STABLE VERSION'
curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/master/docker-compose.yml > docker-compose.new-version.yml
echo 'DOWNLOADING DOCKER COMPOSE FOR NEW VERSION'
curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/v3.1.0/docker-compose.yml > docker-compose.stable-version.yml

/usr/local/bin/docker-compose -f docker-compose.stable-version.yml down --volumes
/usr/local/bin/docker-compose -f docker-compose.new-version.yml down --volumes

/usr/local/bin/docker-compose -f docker-compose.stable-version.yml pull

echo 'STARTING OLD COMPONENT VERSIONS THAT WILL LOAD OLD DEMO DATA TO DATABASE'
/usr/local/bin/docker-compose -f docker-compose.stable-version.yml up --build --force-recreate -d

set -o allexport
source .env
set +o allexport

groovy wait_for_containers.groovy ${BASE_URL}/auth,${BASE_URL}/requisition,${BASE_URL}/referencedata,${BASE_URL}/fulfillment,${BASE_URL}/notification,${BASE_URL}/stockmanagement

returnIfErrors

/usr/local/bin/docker-compose -f docker-compose.stable-version.yml stop

removeService reference-ui
removeService auth
removeService requisition
removeService referencedata
removeService notification
removeService fulfillment
removeService ftp
removeService stockmanagement
removeService log
removeService nginx
removeService consul
removeService service-configuration

echo 'STARTING NEW COMPONENT VERSIONS WITH PRODUCTION FLAG (NO DATA LOSS)'
export spring_profiles_active=production
/usr/local/bin/docker-compose -f docker-compose.new-version.yml up -d

groovy wait_for_containers.groovy ${BASE_URL}/auth,${BASE_URL}/requisition,${BASE_URL}/referencedata,${BASE_URL}/fulfillment,${BASE_URL}/notification,${BASE_URL}/stockmanagement

returnIfErrors

echo '============ LOG MESSAGES FROM STARTING NEW CONTAINERS ============'
/usr/local/bin/docker-compose -f docker-compose.new-version.yml exec log sh -c "cat /var/log/messages"
test_result=`/usr/local/bin/docker-compose -f docker-compose.new-version.yml exec log sh -c "cat /var/log/messages" | grep ERROR | wc -l`

clean

exit ${test_result}
