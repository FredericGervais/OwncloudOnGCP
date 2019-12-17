#
# Description : This script creates a database and a NFS fileshare on
#               GCP. It then sets-up Owncloud containers on a
#               kubernetes cluster
# 
# Author      : Frederic Gervais
# Date        : 2019/12/16
#

IMAGE=owncloud/server:latest
CONTAINER_PORT=8080
NAME=owncloud
DB_USERNAME=root
DB_PREFIX=oc_
STORAGE_NAME=NFSvol
STORAGE_TB_SIZE=2
STORAGE_NETWORK=default
REGION=us-east4

## Auto-filled variables

DB_HOST_NAME=${NAME}-database
DB_NAME=$NAME
DB_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
##
LOWER_CASE=$(echo $STORAGE_NAME | tr '[:upper:]' '[:lower:]')
STORAGE_INSTANCE_ID=${LOWER_CASE}-${RANDOM}${RANDOM}
##
declare -a ZONES
ZONES=($(gcloud compute zones list --filter="REGION:($REGION)" --format="value(name)"))
ZONE=${ZONES[0]}
##


#
# Create a Filestore instance to store the data
#
gcloud filestore instances create $STORAGE_INSTANCE_ID \
--zone=$ZONE \
--tier=STANDARD \
--file-share=name=$STORAGE_NAME,capacity=${STORAGE_TB_SIZE}TB \
--network=name=$STORAGE_NETWORK

#
# Create a MySQL instance on GCP
#
gcloud beta sql instances create $DB_HOST_NAME \
--region $REGION \
--network=default \
--no-assign-ip \
--tier db-n1-standard-4 \
--availability-type REGIONAL \
--enable-bin-log

#
# Create a database on the MySQL instance
#
gcloud sql databases create $DB_NAME \
--instance=$DB_HOST_NAME \
--charset=utf8 \
--collation=utf8_general_ci

#
# Set a known password to the database user
#
FOUND=
FOUND=$(gcloud sql users list --instance=$DB_HOST_NAME --format='value(name)' | grep $DB_USERNAME)

if [ -z $FOUND ]; then
  gcloud sql users create $DB_USERNAME \
--instance=$DB_HOST_NAME \
--password=$DB_PASSWORD
else
  gcloud sql users set-password $DB_USERNAME \
--host=% \
--instance=$DB_HOST_NAME \
--password=$DB_PASSWORD
fi


#
# Create the secrets with the credentials
#
kubectl create secret generic database-credentials --from-literal=username=$DB_USERNAME --from-literal=password=$DB_PASSWORD

#
# Get the IP of the MySQL instance and the Filestore instance
#
DB_HOST=$(gcloud sql instances describe $DB_HOST_NAME | grep ipAddress: | grep -oP '\d+.\d+.\d+.\d+')
STORAGE_HOST=$(gcloud filestore instances describe $STORAGE_INSTANCE_ID --zone $ZONE | grep -A1 ipAddresses: | grep -oP '\d+.\d+.\d+.\d+')

#
# Create the deployment on GKE
#
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $NAME-deployment
  labels:
    app: $NAME
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $NAME
  template:
    metadata:
      labels:
        app: $NAME
    spec:
      volumes:
      - name: nfs-volume
        nfs: 
          server: $STORAGE_HOST
          path: /$STORAGE_NAME
      containers:
      - name: $NAME
        image: $IMAGE
        ports:
        - containerPort: $CONTAINER_PORT
        volumeMounts:
        - name: nfs-volume
          mountPath: /mnt/data
        env:
        - name: OWNCLOUD_DB_TYPE
          value: mysql
        - name: OWNCLOUD_DB_HOST
          value: $DB_HOST
        - name: OWNCLOUD_DB_USERNAME
          valueFrom:
            secretKeyRef:
              name: database-credentials
              key: username
        - name: OWNCLOUD_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: database-credentials
              key: password
        - name: OWNCLOUD_DB_NAME
          value: $DB_NAME
        - name: OWNCLOUD_DB_PREFIX
          value: $DB_PREFIX
        - name: OWNCLOUD_MYSQL_UTF8MB4
          value: “true”
EOF

kubectl expose deployment $NAME-deployment --type=LoadBalancer --name=expose-$NAME