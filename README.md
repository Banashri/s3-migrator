# s3-migrator

This reporsitory describes how you can migrate your s3 bucket from one region in AWS to another region using K8s cronjob.

**NOTE** 

- Typically you can use the AWS provided s3 cp or sync command, but remember that sync command basically migrate newly added objects in your source bucket to destination or modified. This is usually same as the Replication as mentioned in AWS documentation. 

- There are multiple options like aws cp --recursive, sync or mv commands. As per your requirement you can use that inside the sync part of the code.

## Concept

The idea is the run a K8s cronjob in your K8s cluster which basically runs a script for migrating objects from the source to destination s3 bucket.

All the necessary artifacts are added to this repository.


## Pre-requisites

* Create a IAM role in each source and destionation AWS account which has full access to S3. For destination account, the IAM user is `bucket_relocator` (as per the script).
* Versioning is enabled in both source and destination.
* SSE is enabled in buckets. If not, you need to adjust the script accordingly.

## Steps

* Create K8s configmap

You may provide the hard-coded configurations for accounts, buckets or you can populate from the environment variables specified from the cronjob.

This `configmap` object will store the script which would be run by the cronjob.
```
kubectl create configmap scripts --from-file=script.sh -n custom-namespace
```

* Create cron job

```
kubectl create -f cronjob.yaml
```

## License
Licensed under the MIT license
