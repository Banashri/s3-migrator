#!/bin/bash

configure()
{
    export SOURCE_ACCOUNT_USER_PROFILE="<<iam-user>>"
    export SOURCE_ACCOUNT_USER_ACCESS_KEY_ID="<<some_key_id>>"
    export SOURCE_ACCOUNT_USER_SECRET_ACCESS_KEY="<<some_access_key>>"
    export SOURCE_ACCOUNT_REGION="us-central-1"

    export DESTINATION_ACCOUNT_USER_PROFILE="bucket_relocator"
    export DESTINATION_ACCOUNT_USER_ACCESS_KEY_ID="<<dest_some_key_id>>"
    export DESTINATION_ACCOUNT_USER_SECRET_ACCESS_KEY="<<dest_some_access_key>>"
    export DESTINATION_ACCOUNT_REGION="eu-central-1"

    export DESTINATION_ACCOUNT="<<some-account>>"

    export SOURCE_BUCKET="src-bucket"

    export DESTINATION_BUCKET="dest-bucket"

    printf "Setting the credentials ...\n"
    printf "%s\n%s\n%s\njson" "$SOURCE_ACCOUNT_USER_ACCESS_KEY_ID"  "$SOURCE_ACCOUNT_USER_SECRET_ACCESS_KEY" "$SOURCE_ACCOUNT_REGION" |  aws configure --profile "$SOURCE_ACCOUNT_USER_PROFILE"
    printf "%s\n%s\n%s\njson" "$DESTINATION_ACCOUNT_USER_ACCESS_KEY_ID"  "$DESTINATION_ACCOUNT_USER_SECRET_ACCESS_KEY" "$DESTINATION_ACCOUNT_REGION" | aws configure --profile "$DESTINATION_ACCOUNT_USER_PROFILE"
}

check_source_bucket() {

    bucket_count=$(aws s3api list-buckets --query "length(Buckets[?Name==\`$SOURCE_BUCKET\`])" --profile "$SOURCE_ACCOUNT_USER_PROFILE")
    if [ $bucket_count = 0 ]; then
        printf "\nSource bucket does not exist. Try again."
        exit 1
    fi
}

update_bucket_policy()
{
    POLICY_STATEMENT='[
            {
                "Sid": "Stmt1561473971281",
                "Effect": "Allow",
                "Principal": {
                    "AWS": "arn:aws:iam::'$DESTINATION_ACCOUNT':root"
                },
                "Action": [
                    "s3:ListBucket",
                    "s3:GetBucketLocation",
                    "s3:GetObject"
                ],
                "Resource": [
                    "arn:aws:s3:::'$SOURCE_BUCKET'",
                    "arn:aws:s3:::'$SOURCE_BUCKET'/*"
                ]
            }
        ]'

    BUCKET_POLICY='{
        "Version": "2012-10-17",
        "Id": "Policy1561473975184",
        "Statement": '$POLICY_STATEMENT'
    }'

    # Logic to merge the policy
    bucket_policy_exists_check=$(aws s3api --profile "$SOURCE_ACCOUNT_USER_PROFILE" get-bucket-policy --bucket "$SOURCE_BUCKET" --query Policy --output text > policy.json)
    if [ $? != 0 ]
        then
            no_bucket_check=$(echo $s3_check | grep -c 'NoSuchBucketPolicy')
            printf "\nNo bucket policy exists ..  \n"

            printf "\n\nUpdating source bucket policy ...\n"
            aws s3api put-bucket-policy --bucket "$SOURCE_BUCKET" --policy "$BUCKET_POLICY" --profile "$SOURCE_ACCOUNT_USER_PROFILE"

        else
            echo "\n\nChecking if the required grant is present in the existing policy"

            required_bucket_policy_check=$(cat policy.json | jq ".Statement | contains($POLICY_STATEMENT)")
            if $required_bucket_policy_check; then
                printf "\nAccess grant already exists"
            else
                printf "\nGrant is missing. Hence, updating policy\n"

                echo $POLICY_STATEMENT > statement.json

                jq --argjson new_statement "$(<statement.json)" '.Statement += $new_statement' policy.json > temp.json && mv temp.json policy.json

                cat policy.json | jq -r
                aws s3api put-bucket-policy --bucket "$SOURCE_BUCKET" --policy file://policy.json --profile "$SOURCE_ACCOUNT_USER_PROFILE"
                printf "\nBucket policy is updated"
            fi
    fi

    printf "\nSource bucket access granted to destionation account \n"
}

check_destination_bucket() {

    printf "\n\nChecking if the destination bucket exists .. \n"

    s3_check=$(aws s3 ls "s3://${DESTINATION_BUCKET}" --profile "$DESTINATION_ACCOUNT_USER_PROFILE" 2>&1)

    #Some sort of error happened with s3 check
    if [ $? != 0 ]
    then
        no_bucket_check=$(echo $s3_check | grep -c 'NoSuchBucket')

        if [ $no_bucket_check = 1 ]; then
            printf "\n\nBucket $DESTINATION_BUCKET does not exist, hence creating .."
            aws s3 mb "s3://$DESTINATION_BUCKET" --profile "$DESTINATION_ACCOUNT_USER_PROFILE"

            # Bucket policy is added only when a new bucket is created
            DESTINATION_BUCKET_POLICY='{
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Deny",
                        "NotPrincipal": {
                            "AWS": [
                                "arn:aws:iam::'$DESTINATION_ACCOUNT':root",
                                "arn:aws:iam::'$DESTINATION_ACCOUNT':user/some_service",
                                "arn:aws:iam::'$DESTINATION_ACCOUNT':user/'$DESTINATION_ACCOUNT_USER_PROFILE'",
                                "arn:aws:iam::'$DESTINATION_ACCOUNT':user/someuser@gmail.com"
                            ]
                        },
                        "Action": "s3:*",
                        "Resource": [
                            "arn:aws:s3:::'$DESTINATION_BUCKET'",
                            "arn:aws:s3:::'$DESTINATION_BUCKET'/*"
                        ]
                    }
                ]
            }'

            printf "\n\nPutting a restrictive bucket policy\n"
            aws s3api put-bucket-policy --bucket "$DESTINATION_BUCKET" --policy "$DESTINATION_BUCKET_POLICY" --profile "$DESTINATION_ACCOUNT_USER_PROFILE"
            printf "\nBucket policy is added in destination bucket\n"
            printf "\nAdding bucket encryption in destination bucket\n"
            aws s3api put-bucket-encryption --bucket "$DESTINATION_BUCKET" --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' --profile "$DESTINATION_ACCOUNT_USER_PROFILE"
            printf "\nBucket encryption is added in destination bucket\n"
        else
            echo "Error checking S3 Bucket"
            echo "$s3_check"
            exit 1
        fi
    else #bucket exists
        bucket_owner_check=$(aws s3api get-bucket-acl --bucket "$DESTINATION_BUCKET" --query "Owner.DisplayName=='aws-$DESTINATION_ACCOUNT'" --profile "$DESTINATION_ACCOUNT_USER_PROFILE" 2>&1)
        if $bucket_owner_check; then
            printf "Destination bucket belongs to the destination account"
        else
            printf "Sorry. Destination account has no permission to this bucket"
            exit 1
        fi
    fi
}

transfer()
{
    configure
    check_source_bucket
    update_bucket_policy
    check_destination_bucket

    sync_buckets
}

sync_buckets() {

    aws configure set default.s3.max_concurrent_requests 200 --profile "$DESTINATION_ACCOUNT_USER_PROFILE"

    printf "\n\nMigrating bucket $SOURCE_BUCKET to $DESTINATION_BUCKET .. \n"
    start=$(date +"%s")
    # aws s3 sync "s3://$SOURCE_BUCKET" "s3://$DESTINATION_BUCKET" --sse --profile "$DESTINATION_ACCOUNT_USER_PROFILE"
    
    end=$(date +"%s")
    diff=$(($end - $start))
    printf "\n\nMigration execution time is : $(($diff / 60)) minutes and $(($diff % 60)) seconds"
}

transfer
exit 0
