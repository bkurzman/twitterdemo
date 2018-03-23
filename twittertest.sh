#!/bin/bash

installUtils () {
	echo "*********************************Installing WGET..."
	yum install -y wget
	
	
	echo "*********************************Installing GIT..."
	yum install -y git
	

}

instalHDFManagementPack () {
	wget http://public-repo-1.hortonworks.com/HDF/centos7/3.x/updates/3.0.1.1/tars/hdf_ambari_mp/hdf-ambari-mpack-3.0.1.1-5.tar.gz
ambari-server install-mpack --mpack=hdf-ambari-mpack-3.0.1.1-5.tar.gz --verbose

	sleep 2
	ambari-server restart
	waitForAmbari
	sleep 2
}

installNifi() {
	#change this to management packs code

	VERSION=`hdp-select status hadoop-client | sed 's/hadoop-client - \([0-9]\.[0-9]\).*/\1/'`
	rm -rf /var/lib/ambari-server/resources/stacks/HDP/$VERSION/services/NIFI
	sudo git clone https://github.com/abajwa-hw/ambari-nifi-service.git   /var/lib/ambari-server/resources/stacks/HDP/$VERSION/services/NIFI   
	#non sandbox
	service ambari-server restart
}

installSolr() {
	#change this to management packs code

	yum install -y lucidworks-hdpsearch
	sudo -u hdfs hadoop fs -mkdir /user/solr
	sudo -u hdfs hadoop fs -chown solr /user/solr
}

initializeSolr () {
	cd /opt/lucidworks-hdpsearch/solr/server/solr-webapp/webapp/banana/app/dashboards/
	mv default.json default.json.orig
	wget https://raw.githubusercontent.com/abajwa-hw/ambari-nifi-service/master/demofiles/default.json

	cd /opt/lucidworks-hdpsearch/solr/server/solr/configsets/data_driven_schema_configs/conf
 	mv -f solrconfig.xml solrconfig_bk.xml

  	wget https://raw.githubusercontent.com/sujithasankuhdp/nifi-templates/master/templates/solrconfig.xml
}

startSolr() {
  /opt/lucidworks-hdpsearch/solr/bin/solr start -c -z $AMBARI_HOST:2181
  /opt/lucidworks-hdpsearch/solr/bin/solr create -c tweets -d data_driven_schema_configs -s 1 -rf 1 
  yum install -y ntp
  service ntpd stop
  ntpdate pool.ntp.org
  service ntpd start
}

createHiveTables () {
  sudo -u hdfs hadoop fs -mkdir /tmp/tweets_staging
  sudo -u hdfs hadoop fs -chmod -R 777 /tmp/tweets_staging


  sudo -u hdfs hive -e 'create table if not exists tweets_text_partition(
    tweet_id bigint, 
    created_unixtime bigint, 
    created_time string, 
    displayname string, 
  msg string,
  fulltext string
  )
  row format delimited fields terminated by "|"
  location "/tmp/tweets_staging";'
}

deployTemplateToNifi () {
       	TEMPLATE_DIR=$1
       	TEMPLATE_NAME=$2
       	
       	echo "*********************************Importing NIFI Template..."
       	# Import NIFI Template HDF 3.x
       	# TEMPLATE_DIR should have been passed in by the caller install process
       	sleep 1
       	TEMPLATEID=$(curl -v -F template=@"$TEMPLATE_DIR" -X POST http://$NIFI_HOST:9090/nifi-api/process-groups/root/templates/upload | grep -Po '<id>([a-z0-9-]+)' | grep -Po '>([a-z0-9-]+)' | grep -Po '([a-z0-9-]+)')
       	sleep 1

       	# Instantiate NIFI Template 3.x
       	echo "*********************************Instantiating NIFI Flow..."
       	curl -u admin:admin -i -H "Content-Type:application/json" -d "{\"templateId\":\"$TEMPLATEID\",\"originX\":100,\"originY\":100}" -X POST http://$NIFI_HOST:9090/nifi-api/process-groups/root/template-instance
       	sleep 1

       	# Rename NIFI Root Group HDF 3.x
       	echo "*********************************Renaming Nifi Root Group..."
       	ROOT_GROUP_REVISION=$(curl -X GET http://$NIFI_HOST:9090/nifi-api/process-groups/root |grep -Po '\"version\":([0-9]+)'|grep -Po '([0-9]+)')

       	sleep 1
       	ROOT_GROUP_ID=$(curl -X GET http://$NIFI_HOST:9090/nifi-api/process-groups/root|grep -Po '("component":{"id":")([0-9a-zA-z\-]+)'| grep -Po '(:"[0-9a-zA-z\-]+)'| grep -Po '([0-9a-zA-z\-]+)')

       	PAYLOAD=$(echo "{\"id\":\"$ROOT_GROUP_ID\",\"revision\":{\"version\":$ROOT_GROUP_REVISION},\"component\":{\"id\":\"$ROOT_GROUP_ID\",\"name\":\"$TEMPLATE_NAME\"}}")

       	sleep 1
       	curl -d $PAYLOAD  -H "Content-Type: application/json" -X PUT http://$NIFI_HOST:9090/nifi-api/process-groups/$ROOT_GROUP_ID

}

configureNifiTempate () {
	GROUP_TARGETS=$(curl -u admin:admin -i -X GET http://$AMBARI_HOST:9090/nifi-api/process-groups/root/process-groups | grep -Po '\"uri\":\"([a-z0-9-://.]+)' | grep -Po '(?!.*\")([a-z0-9-://.]+)')
    length=${#GROUP_TARGETS[@]}
    echo $length
    echo ${GROUP_TARGETS[0]}

    #for ((i = 0; i < $length; i++))
    for GROUP in $GROUP_TARGETS
    do
       	#CURRENT_GROUP=${GROUP_TARGETS[i]}
       	CURRENT_GROUP=$GROUP
       	echo "***********************************************************calling handle ports with group $CURRENT_GROUP"
       	handleGroupPorts $CURRENT_GROUP
       	echo "***********************************************************calling handle processors with group $CURRENT_GROUP"
       	handleGroupProcessors $CURRENT_GROUP
       	echo "***********************************************************done handle processors"
    done

    ROOT_TARGET=$(curl -u admin:admin -i -X GET http://$AMBARI_HOST:9090/nifi-api/process-groups/root| grep -Po '\"uri\":\"([a-z0-9-://.]+)' | grep -Po '(?!.*\")([a-z0-9-://.]+)')

    handleGroupPorts $ROOT_TARGET

    handleGroupProcessors $ROOT_TARGET
}

handleGroupProcessors (){
       	TARGET_GROUP=$1

       	TARGETS=($(curl -u admin:admin -i -X GET $TARGET_GROUP/processors | grep -Po '\"uri\":\"([a-z0-9-://.]+)' | grep -Po '(?!.*\")([a-z0-9-://.]+)'))
       	length=${#TARGETS[@]}
       	echo $length
       	echo ${TARGETS[0]}

       	for ((i = 0; i < $length; i++))
       	do
       		ID=$(curl -u admin:admin -i -X GET ${TARGETS[i]} |grep -Po '"id":"([a-zA-z0-9\-]+)'|grep -Po ':"([a-zA-z0-9\-]+)'|grep -Po '([a-zA-z0-9\-]+)'|head -1)
       		REVISION=$(curl -u admin:admin -i -X GET ${TARGETS[i]} |grep -Po '\"version\":([0-9]+)'|grep -Po '([0-9]+)')
       		TYPE=$(curl -u admin:admin -i -X GET ${TARGETS[i]} |grep -Po '"type":"([a-zA-Z0-9\-.]+)' |grep -Po ':"([a-zA-Z0-9\-.]+)' |grep -Po '([a-zA-Z0-9\-.]+)' |head -1)
       		echo "Current Processor Path: ${TARGETS[i]}"
       		echo "Current Processor Revision: $REVISION"
       		echo "Current Processor ID: $ID"
       		echo "Current Processor TYPE: $TYPE"

       			if ! [ -z $(echo $TYPE|grep "Record") ]; then
       				echo "***************************This is a Record Processor"

       				RECORD_READER=$(curl -u admin:admin -i -X GET ${TARGETS[i]} |grep -Po '"record-reader":"[a-zA-Z0-9-]+'|grep -Po ':"[a-zA-Z0-9-]+'|grep -Po '[a-zA-Z0-9-]+'|head -1)
                RECORD_WRITER=$(curl -u admin:admin -i -X GET ${TARGETS[i]} |grep -Po '"record-writer":"[a-zA-Z0-9-]+'|grep -Po ':"[a-zA-Z0-9-]+'|grep -Po '[a-zA-Z0-9-]+'|head -1)

                echo "Record Reader: $RECORD_READER"
                echo "Record Writer: $RECORD_WRITER"

       				SCHEMA_REGISTRY=$(curl -u admin:admin -i -X GET http://$AMBARI_HOST:9090/nifi-api/controller-services/$RECORD_READER |grep -Po '"schema-registry":"[a-zA-Z0-9-]+'|grep -Po ':"[a-zA-Z0-9-]+'|grep -Po '[a-zA-Z0-9-]+'|head -1)

       				echo "Schema Registry: $SCHEMA_REGISTRY"

       				curl -u admin:admin -i -H "Content-Type:application/json" -X PUT -d "{\"id\":\"$SCHEMA_REGISTRY\",\"revision\":{\"version\":$REVISION},\"component\":{\"id\":\"$SCHEMA_REGISTRY\",\"state\":\"ENABLED\",\"properties\":{\"url\":\"http:\/\/$AMBARI_HOST:7788\/api\/v1\"}}}" http://$AMBARI_HOST:9090/nifi-api/controller-services/$SCHEMA_REGISTRY

       				curl -u admin:admin -i -H "Content-Type:application/json" -X PUT -d "{\"id\":\"$RECORD_READER\",\"revision\":{\"version\":$REVISION},\"component\":{\"id\":\"$RECORD_READER\",\"state\":\"ENABLED\"}}" http://$AMBARI_HOST:9090/nifi-api/controller-services/$RECORD_READER

       				curl -u admin:admin -i -H "Content-Type:application/json" -X PUT -d "{\"id\":\"$RECORD_WRITER\",\"revision\":{\"version\":$REVISION},\"component\":{\"id\":\"$RECORD_WRITER\",\"state\":\"ENABLED\"}}" http://$AMBARI_HOST:9090/nifi-api/controller-services/$RECORD_WRITER

       			fi
       		if ! [ -z $(echo $TYPE|grep "PutKafka") ] || ! [ -z $(echo $TYPE|grep "PublishKafka") ]; then
       			echo "***************************This is a PutKafka Processor"
       			echo "***************************Updating Kafka Broker Porperty and Activating Processor..."
       			if ! [ -z $(echo $TYPE|grep "PutKafka") ]; then
                    PAYLOAD=$(echo "{\"id\":\"$ID\",\"revision\":{\"version\":$REVISION},\"component\":{\"id\":\"$ID\",\"config\":{\"properties\":{\"Known Brokers\":\"$AMBARI_HOST:6667\"}},\"state\":\"RUNNING\"}}")
                else
                    PAYLOAD=$(echo "{\"id\":\"$ID\",\"revision\":{\"version\":$REVISION},\"component\":{\"id\":\"$ID\",\"config\":{\"properties\":{\"bootstrap.servers\":\"$AMBARI_HOST:6667\"}},\"state\":\"RUNNING\"}}")
                fi
       		else
       			echo "***************************Activating Processor..."
       				PAYLOAD=$(echo "{\"id\":\"$ID\",\"revision\":{\"version\":$REVISION},\"component\":{\"id\":\"$ID\",\"state\":\"RUNNING\"}}")
       			fi
       		echo "$PAYLOAD"

       		curl -u admin:admin -i -H "Content-Type:application/json" -d "${PAYLOAD}" -X PUT ${TARGETS[i]}
       	done
}

handleGroupPorts (){
       	TARGET_GROUP=$1

       	TARGETS=($(curl -u admin:admin -i -X GET $TARGET_GROUP/output-ports | grep -Po '\"uri\":\"([a-z0-9-://.]+)' | grep -Po '(?!.*\")([a-z0-9-://.]+)'))
       	length=${#TARGETS[@]}
       	echo $length
       	echo ${TARGETS[0]}

       	for ((i = 0; i < $length; i++))
       	do
       		ID=$(curl -u admin:admin -i -X GET ${TARGETS[i]} |grep -Po '"id":"([a-zA-z0-9\-]+)'|grep -Po ':"([a-zA-z0-9\-]+)'|grep -Po '([a-zA-z0-9\-]+)'|head -1)
       		REVISION=$(curl -u admin:admin -i -X GET ${TARGETS[i]} |grep -Po '\"version\":([0-9]+)'|grep -Po '([0-9]+)')
       		TYPE=$(curl -u admin:admin -i -X GET ${TARGETS[i]} |grep -Po '"type":"([a-zA-Z0-9\-.]+)' |grep -Po ':"([a-zA-Z0-9\-.]+)' |grep -Po '([a-zA-Z0-9\-.]+)' |head -1)
       		echo "Current Processor Path: ${TARGETS[i]}"
       		echo "Current Processor Revision: $REVISION"
       		echo "Current Processor ID: $ID"

       		echo "***************************Activating Port ${TARGETS[i]}..."

       		PAYLOAD=$(echo "{\"id\":\"$ID\",\"revision\":{\"version\":$REVISION},\"component\":{\"id\":\"$ID\",\"state\": \"RUNNING\"}}")

       		echo "PAYLOAD"
       		curl -u admin:admin -i -H "Content-Type:application/json" -d "${PAYLOAD}" -X PUT ${TARGETS[i]}
       	done
}

installNifiService () {
       	echo "*********************************Creating NIFI service..."
       	# Create NIFI service
       	curl -u admin:admin -H "X-Requested-By:ambari" -i -X POST http://$AMBARI_HOST:8080/api/v1/clusters/$CLUSTER_NAME/services/NIFI

       	sleep 2
       	echo "*********************************Adding NIFI MASTER component..."
       	# Add NIFI Master component to service
       	curl -u admin:admin -H "X-Requested-By:ambari" -i -X POST http://$AMBARI_HOST:8080/api/v1/clusters/$CLUSTER_NAME/services/NIFI/components/NIFI_MASTER
		curl -u admin:admin -H "X-Requested-By:ambari" -i -X POST http://$AMBARI_HOST:8080/api/v1/clusters/$CLUSTER_NAME/services/NIFI/components/NIFI_CA
		
       	sleep 2
       	echo "*********************************Creating NIFI configuration..."

       	# Create and apply configuration
		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-ambari-config $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-ambari-config.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-ambari-ssl-config $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-ambari-ssl-config.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-authorizers-env $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-authorizers-env.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-bootstrap-env $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-bootstrap-env.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-bootstrap-notification-services-env $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-bootstrap-notification-services-env.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-env $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-env.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-flow-env $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-flow-env.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-login-identity-providers-env $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-login-identity-providers-env.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-node-logback-env $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-node-logback-env.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-properties $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-properties.json

		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-state-management-env $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-state-management-env.json
		
		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-jaas-conf $ROOT_PATH/Twitter/hdf-config/nifi-config/nifi-jaas-conf.json
				
		/var/lib/ambari-server/resources/scripts/configs.sh set $AMBARI_HOST $CLUSTER_NAME nifi-logsearch-conf $ROOT_PATH/CloudBreakArtifacts/hdf-config/nifi-config/nifi-logsearch-conf.json
		
       	echo "*********************************Adding NIFI MASTER role to Host..."
       	# Add NIFI Master role to Ambari Host
       	curl -u admin:admin -H "X-Requested-By:ambari" -i -X POST http://$AMBARI_HOST:8080/api/v1/clusters/$CLUSTER_NAME/hosts/$AMBARI_HOST/host_components/NIFI_MASTER

       	echo "*********************************Adding NIFI CA role to Host..."
		# Add NIFI CA role to Ambari Host
       	curl -u admin:admin -H "X-Requested-By:ambari" -i -X POST http://$AMBARI_HOST:8080/api/v1/clusters/$CLUSTER_NAME/hosts/$AMBARI_HOST/host_components/NIFI_CA

       	sleep 30
       	echo "*********************************Installing NIFI Service"
       	# Install NIFI Service
       	TASKID=$(curl -u admin:admin -H "X-Requested-By:ambari" -i -X PUT -d '{"RequestInfo": {"context" :"Install Nifi"}, "Body": {"ServiceInfo": {"maintenance_state" : "OFF", "state": "INSTALLED"}}}' http://$AMBARI_HOST:8080/api/v1/clusters/$CLUSTER_NAME/services/NIFI | grep "id" | grep -Po '([0-9]+)')
		
		sleep 2       	
       	if [ -z $TASKID ]; then
       		until ! [ -z $TASKID ]; do
       			TASKID=$(curl -u admin:admin -H "X-Requested-By:ambari" -i -X PUT -d '{"RequestInfo": {"context" :"Install Nifi"}, "Body": {"ServiceInfo": {"maintenance_state" : "OFF", "state": "INSTALLED"}}}' http://$AMBARI_HOST:8080/api/v1/clusters/$CLUSTER_NAME/services/NIFI | grep "id" | grep -Po '([0-9]+)')
       		 	echo "*********************************AMBARI TaskID " $TASKID
       		done
       	fi
       	
       	echo "*********************************AMBARI TaskID " $TASKID
       	sleep 2
       	LOOPESCAPE="false"
       	until [ "$LOOPESCAPE" == true ]; do
               	TASKSTATUS=$(curl -u admin:admin -X GET http://$AMBARI_HOST:8080/api/v1/clusters/$CLUSTER_NAME/requests/$TASKID | grep "request_status" | grep -Po '([A-Z]+)')
               	if [ "$TASKSTATUS" == COMPLETED ]; then
                       	LOOPESCAPE="true"
               	fi
               	echo "*********************************Task Status" $TASKSTATUS
               	sleep 2
       	done
}


waitForNifiServlet () {
       	LOOPESCAPE="false"
       	until [ "$LOOPESCAPE" == true ]; do
       		TASKSTATUS=$(curl -u admin:admin -i -X GET http://$AMBARI_HOST:9090/nifi-api/controller | grep -Po 'OK')
       		if [ "$TASKSTATUS" == OK ]; then
               		LOOPESCAPE="true"
       		else
               		TASKSTATUS="PENDING"
       		fi
       		echo "*********************************Waiting for NIFI Servlet..."
       		echo "*********************************NIFI Servlet Status... " $TASKSTATUS
       		sleep 2
       	done
}

export AMBARI_HOST=$(hostname -f)
echo "*********************************AMABRI HOST IS: $AMBARI_HOST"

export ROOT_PATH=~
echo "*********************************ROOT PATH IS: $ROOT_PATH"

export VERSION=`hdp-select status hadoop-client | sed 's/hadoop-client - \([0-9]\.[0-9]\).*/\1/'`
export INTVERSION=$(echo $VERSION*10 | bc | grep -Po '([0-9][0-9])')
echo "*********************************HDP VERSION IS: $VERSION"

echo "****************Installing Utilities"
installUtils
echo "*********************************Install HDF Management Pack..."
instalHDFManagementPack 

sleep 2
installNifiService

sleep 2
NIFI_STATUS=$(getServiceStatus NIFI)
echo "*********************************Checking NIFI status..."
if ! [[ $NIFI_STATUS == STARTED || $NIFI_STATUS == INSTALLED ]]; then
       	echo "*********************************NIFI is in a transitional state, waiting..."
       	waitForService NIFI
       	echo "*********************************NIFI has entered a ready state..."
fi

sleep 2

if [[ $NIFI_STATUS == INSTALLED ]]; then
       	startServiceAndComplete NIFI
else
       	echo "*********************************NIFI Service Started..."
fi

sleep 2

echo "****************Installing Solr"
installSolr
echo "****************Initializing Solr"
initializeSolr
echo "****************Starting Solr"
startSolr
echo "****************Creative Hive Tables"
createHiveTables
echo "********************************* Deploying Nifi Template"
deployTemplateToNifi $ROOT_PATH/SE-demo/Twitter/Twitter_Dashboard.xml TWITTER-Demo
echo "********************************* Configuring Nifi Template"
configureNifiTempate
