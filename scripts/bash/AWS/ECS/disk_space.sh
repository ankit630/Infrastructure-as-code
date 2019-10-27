# For more details on use case for this script visit https://www.unixcloudfusion.in/2019/10/solved-cannotpullcontainererror-no.html
echo "---------------------------------------------------------------------------------------"
                  echo "Disk space monitoring for ecs instances"
                  cat << EOF > /tmp/disk_space.sh
                  #! /usr/bin/env bash
                  set -o pipefail
                  set -o nounset
                  set -o errexit

                  metadata=\$(curl -s http://localhost:51678/v1/metadata)

                  clusterName=\$(jq -r .Cluster <<< \$metadata)
                  instanceArn=\$(jq -r '. | .ContainerInstanceArn' <<< \$metadata | awk -F/ '{print \$NF}')
                  region=\$(jq -r '. | .ContainerInstanceArn' <<< \$metadata | awk -F: '{print \$4}')
                  instanceStatus=\$(aws ecs describe-container-instances --region \$region --cluster \$clusterName --container-instances \$instanceArn | jq -r .containerInstances[].status)

                  function drainInstance {
                    if [ "\$instanceStatus" == "ACTIVE" ]; then
                      aws ecs update-container-instances-state \
                        --cluster "\$clusterName" \
                        --container-instances "\$instanceArn" \
                        --status "DRAINING" \
                        --region "\$region"
                      else
                        echo "Can't drain - instance status: \$instanceStatus"
                    fi
                  }

                  function deregisterInstance {
                    containersCount=\$(docker ps -q | wc -l | xargs)
                    if [ "\$instanceStatus" == "DRAINING" ] && [ \$containersCount -le 3 ]; then
                      aws ecs deregister-container-instance \
                        --cluster "\$clusterName" \
                        --container-instance "\$instanceArn" \
                        --region "\$region" && \
                      aws cloudwatch put-metric-data \
                      --metric-name deregisteredLowSpaceInstances \
                      --namespace ECS_Health \
                      --value 1 \
                      --dimensions Cluster="\$clusterName" --region "\$region"
                      else
                        echo "Can't deregister - instance status: \$instanceStatus"
                        echo "Running containers: \$containersCount"
                    fi
                  }

                  SpaceUsedPercent=\$(df -t ext4 --output=pcent |grep -o '[0-9]*')
                  
                  aws ecs put-attributes \
                    --cluster "\$clusterName" \
                    --attributes name="SpaceUsedPercent",value="\$SpaceUsedPercent",targetType="container-instance",targetId="\$instanceArn" \
                    --region "\$region"

                  if [ \$SpaceUsedPercent -gt 85 ]; then 
                    drainInstance
                    deregisterInstance
                  fi
                  EOF
                  chmod +x /tmp/disk_space.sh
                  echo "*/5 * * * * root /tmp/disk_space.sh" >> /etc/crontab
