#!/bin/bash
set -e

## source of this code: https://github.com/labs42io/circleci-monorepo/blob/master/.circleci/circle_trigger.sh

# The root directory of packages.
# Use `.` if your packages are located in root.
ROOT="." 
REPOSITORY_TYPE="github"
CIRCLE_API="https://circleci.com/api"
DEFAULT_BRANCH='master'

############################################
## 0. Check for layer 8 errors
############################################
sudo apt install jq -y

if  [[ ${CIRCLE_TOKEN} == "" ]]; then
  SCRIPT=`realpath $0`
  echo "You need to set CIRCLE_TOKEN as ENV-var, or this script (${SCRIPT}) will fail!"
  exit 1
fi

############################################
## 1. Commit SHA of last CI build
############################################
LAST_COMPLETED_BUILD_URL="${CIRCLE_API}/v1.1/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${CIRCLE_BRANCH}?filter=completed&limit=100&shallow=true"
LAST_COMPLETED_BUILD_SHA=`curl -Ss -u "${CIRCLE_TOKEN}:" "${LAST_COMPLETED_BUILD_URL}" | jq -r 'map(select(.status == "success") | select(.workflows.workflow_name != "ci")) | .[0]["vcs_revision"]'`

if  [[ ${LAST_COMPLETED_BUILD_SHA} == "null" ]]; then
  echo -e "\e[93mThere are no completed CI builds in branch ${CIRCLE_BRANCH}.\e[0m"

  # Adapted from https://gist.github.com/joechrysler/6073741
  TREE=$(git show-branch -a \
    | grep '\*' \
    | grep -v `git rev-parse --abbrev-ref HEAD` \
    | sed 's/.*\[\(.*\)\].*/\1/' \
    | sed 's/[\^~].*//' \
    | uniq)

  REMOTE_BRANCHES=$(git branch -r | sed 's/\s*origin\///' | tr '\n' ' ')
  PARENT_BRANCH=${DEFAULT_BRANCH}
  for BRANCH in ${TREE[@]}
  do
    BRANCH=${BRANCH#"origin/"}
    if [[ " ${REMOTE_BRANCHES[@]} " == *" ${BRANCH} "* ]]; then
      echo "Found the parent branch: ${CIRCLE_BRANCH}..${BRANCH}"
      PARENT_BRANCH=$BRANCH
      break
    fi
  done

  echo "Searching for CI builds in branch '${PARENT_BRANCH}' ..."

  LAST_COMPLETED_BUILD_URL="${CIRCLE_API}/v1.1/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${PARENT_BRANCH}?filter=completed&limit=100&shallow=true"
  LAST_COMPLETED_BUILD_SHA=`curl -Ss -u "${CIRCLE_TOKEN}:" "${LAST_COMPLETED_BUILD_URL}" \
    | jq -r "map(\
      select(.status == \"success\") | select(.workflows.workflow_name != \"ci\") | select(.build_num < ${CIRCLE_BUILD_NUM})) \
    | .[0][\"vcs_revision\"]"`
fi

if [[ ${LAST_COMPLETED_BUILD_SHA} == "null" ]]; then
  echo -e "\e[93mNo CI builds for branch ${PARENT_BRANCH}. Using ${DEFAULT_BRANCH}.\e[0m"
  LAST_COMPLETED_BUILD_SHA=${DEFAULT_BRANCH}
fi

############################################
## 2. Changed packages
############################################
PACKAGES=$(ls ${ROOT} -l | grep ^d | awk '{print $9}')
echo "Searching for changes since commit [${LAST_COMPLETED_BUILD_SHA:0:7}] ..."

if [[ $LAST_COMPLETED_BUILD_SHA == $DEFAULT_BRANCH ]]; then
  FORCE_ALL_PACKS=true
fi

## The CircleCI API parameters object
PARAMETERS='"trigger":false'
COUNT=0
for PACKAGE in ${PACKAGES[@]}
do
  PACKAGE_PATH=${ROOT}/$PACKAGE
  LATEST_COMMIT_SINCE_LAST_BUILD=$(git log -1 $CIRCLE_SHA1 ^$LAST_COMPLETED_BUILD_SHA --format=format:%H --full-diff ${PACKAGE_PATH#/})

  if [ -n "$LATEST_COMMIT_SINCE_LAST_BUILD" ] || [ -n "$FORCE_ALL_PACKS" ]; then
    PARAMETERS+=", \"$PACKAGE\":true"
    
    if [[ -n $FORCE_ALL_PACKS ]]; then
      echo -e "\e[36m  [+] ${PACKAGE} \e[21m will be triggered because we are on the default branch: ${DEFAULT_BRANCH} \e[0m"
    else
      COUNT=$((COUNT + 1))
      echo -e "\e[36m  [+] ${PACKAGE} \e[21m (changed in [${LATEST_COMMIT_SINCE_LAST_BUILD:0:7}])\e[0m"
    fi
  else
    echo -e "\e[90m  [-] ${PACKAGE} \e[0m"
  fi

done

if [[ $COUNT -eq 0 ]]; then
  echo -e "\e[93mNo changes detected in packages. Skip triggering workflows.\e[0m"
  exit 0
fi

echo "Changes detected in ${COUNT} package(s)."

############################################
## 3. CicleCI REST API call
############################################
DATA="{ \"branch\": \"$CIRCLE_BRANCH\", \"parameters\": { $PARAMETERS } }"
echo "Triggering pipeline with data:"
echo -e "  $DATA"

URL="${CIRCLE_API}/v2/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline"
HTTP_RESPONSE=$(curl -s -u ${CIRCLE_TOKEN}: -o response.txt -w "%{http_code}" -X POST --header "Content-Type: application/json" -d "$DATA" $URL)

if [ "$HTTP_RESPONSE" -ge "200" ] && [ "$HTTP_RESPONSE" -lt "300" ]; then
  echo "API call succeeded."
  echo "Response:"
  cat response.txt
else
  echo -e "\e[93mReceived status code: ${HTTP_RESPONSE}\e[0m"
  echo "Response:"
  cat response.txt
  exit 1
fi
