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
    sleep 15
    services_list=`curl -s 'http://localhost:8500/v1/catalog/services' | sed -e 's/[{}"]/''/g' | awk -v RS=',' -F: '{print $1}' |  grep -v consul | grep -v reference-ui | paste -sd ","`
    IFS=',' read -r -a services_array <<< "$services_list"

    if [ ${#services_array[@]} -eq 0 ]; then
        echo "service list is empty :("
        clean
        exit 1
    fi

    echo "waiting for ${services_array[*]} to be started up and serving"
    for service in "${services_array[@]}"
    do
        counter=0
        while [[ $counter -lt 50 ]]; do
            let counter=counter+1
            echo "trying $service $counter times"
            service_response=`curl http://localhost/$service 2> /dev/null`
            if [[ $service_response == {* ]]; then
                break
            fi
            if [[ $counter == 50 ]]; then
                echo "TIMED OUT WAITING FOR SERVICE $service"
                clean
                exit 1
            fi
            if [[ $1 == "test" ]]; then
                test_result=`/usr/local/bin/docker-compose -f docker-compose.new-version.yml exec -T log sh -c "cat /var/log/messages" | grep ERROR | wc -l`
                if [[ $test_result -ne 0 ]]; then
                    echo '============ LOG ERRORS FROM STARTING NEW CONTAINERS ============'
                    /usr/local/bin/docker-compose -f docker-compose.new-version.yml exec -T log sh -c "cat /var/log/messages" | grep -v Resource2Db
                    echo "MIGRATION TESTS FAILURE"
                    clean
                    exit 3
                else
                    /usr/local/bin/docker-compose -f docker-compose.new-version.yml exec -T log sh -c "cat /var/log/messages" | grep -v Resource2Db
                fi
            elif [[ $1 == "prep" ]]; then
               /usr/local/bin/docker-compose -f docker-compose.stable-version.yml exec -T log sh -c "cat /var/log/messages" | grep -v Resource2Db
            fi
            sleep 5
        done
    done
}

remove_invalid_lots() {
  # The following LOTs have incorrect value in tradeItemId column and they
  # have to be removed before we start new component versions
  LOTS=('35c81bde-e975-4603-ab3b-5ae1dafe9d33' '639f0bc5-0372-4a0e-9a9d-b0144ceb0474' 'cb0e7132-e364-4143-a996-0c2cbc740bb0' 'd5703c4f-82fd-4fac-8214-ed2eb1094f1a')
  DB_CONTAINER=$(/usr/local/bin/docker-compose -f docker-compose.stable-version.yml ps | awk '{ print $1 }' | grep db)

  for LOT in "${LOTS[@]}"
  do
    /usr/bin/docker exec -e LOT_ID=${LOT} ${DB_CONTAINER} /bin/bash -c "export PGPASSWORD=\${POSTGRES_PASSWORD} && psql \${DATABASE_URL:5} -U\${POSTGRES_USER} -c \"DELETE FROM referencedata.lots WHERE id = '\${LOT_ID}'\""
  done
}

STABLE_VERSION=${STABLE_VERSION:-v3.1.1}
NEW_VERSION=${NEW_VERSION:-master}

mkdir -p build

if [[ ${STABLE_VERSION} =~ ^v3\.[3-9].* ]]; then
  cp .env build/settings.env
  curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/${STABLE_VERSION}/.env > build/.env
else
  cp .env build/
fi

cp -r config build/
cd build

echo "DOWNLOADING DOCKER COMPOSE FOR STABLE VERSION $STABLE_VERSION"
curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/${STABLE_VERSION}/docker-compose.yml > docker-compose.stable-version.yml
echo "DOWNLOADING DOCKER COMPOSE FOR NEW VERSION $NEW_VERSION"
curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/${NEW_VERSION}/docker-compose.yml > docker-compose.new-version.yml

clean
/usr/local/bin/docker-compose -f docker-compose.stable-version.yml pull

sed -i '/spring_profiles_active=.*/d' settings.env
sed -i "\$aspring_profiles_active=demo-data,refresh-db" settings.env

echo 'STARTING OLD COMPONENT VERSIONS THAT WILL LOAD OLD DEMO DATA TO DATABASE'
/usr/local/bin/docker-compose -f docker-compose.stable-version.yml up --build --force-recreate -d

wait_for_services prep
remove_invalid_lots
echo 'REMOVING OLD CONTAINERS EXCEPT DATABASE'
/usr/local/bin/docker-compose -f docker-compose.stable-version.yml stop > /dev/null 2> /dev/null
docker rm -f `/usr/local/bin/docker-compose -f docker-compose.stable-version.yml ps | grep build | grep -v db | awk '{ print $1 }' | paste -sd " "`

echo 'STARTING NEW COMPONENT VERSIONS WITH PRODUCTION FLAG (NO DATA LOSS)'
sed -i '/spring_profiles_active=.*/d' settings.env
sed -i "\$aspring_profiles_active=production" settings.env

if ! [[ ${STABLE_VERSION} =~ ^v3\.[3-9].* ]]; then
  mv .env settings.env
fi

curl https://raw.githubusercontent.com/OpenLMIS/openlmis-ref-distro/${NEW_VERSION}/.env > .env

/usr/local/bin/docker-compose -f docker-compose.new-version.yml up --no-recreate -d

wait_for_services test

echo "MIGRATION TESTS SUCCESS"
clean
exit ${test_result}
