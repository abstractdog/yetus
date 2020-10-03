#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# no public APIs here
# SHELLDOC-IGNORE

# This bug system provides github integration

add_bugsystem github

# personalities can override the following settings:

# Web interface URL.
GITHUB_BASE_URL="https://github.com"

# API interface URL.
GITHUB_API_URL="https://api.github.com"

# user/repo
GITHUB_REPO=""

# user settings
GITHUB_PASSWD="${GITHUB_PASSWD-}"
GITHUB_USER="${GITHUB_USER-}"
GITHUB_TOKEN="${GITHUB_TOKEN-}"
GITHUB_ISSUE=""
GITHUB_USE_EMOJI_VOTE=false
declare -a GITHUB_AUTH

# private globals...
GITHUB_BRIDGED=false

# Simple function to set a default GitHub user after PROJECT_NAME has been set
function github_set_github_user
{
  if [[ -n "${PROJECT_NAME}" && ! "${PROJECT_NAME}" = unknown ]]; then
    GITHUB_USER=${GITHUB_USER:-"${PROJECT_NAME}qa"}
  fi
}

function github_usage
{
  github_set_github_user

  yetus_add_option "--github-api-url=<url>" "The URL of the API for github (default: '${GITHUB_API_URL}')"
  yetus_add_option "--github-base-url=<url>" "The URL of the github server (default:'${GITHUB_BASE_URL}')"
# Do not extract GITHUB_PASSWD environment variable
  yetus_add_option "--github-password=<pw>" "Github password (or OAuth token) (default: 'GITHUB_PASSWD' environment variable)"
  yetus_add_option "--github-repo=<repo>" "github repo to use (default:'${GITHUB_REPO}')"
  yetus_add_option "--github-token=<token>" "The token to use to read/write to github"
  yetus_add_option "--github-user=<user>" "Github user [default: ${GITHUB_USER}]"
  yetus_add_option "--github-use-emoji-vote" "Whether to use emoji to represent the vote result on github [default: ${GITHUB_USE_EMOJI_VOTE}]"
}

function github_parse_args
{
  declare i

  github_set_github_user

  for i in "$@"; do
    case ${i} in
      --github-api-url=*)
        delete_parameter "${i}"
        GITHUB_API_URL=${i#*=}
      ;;
      --github-base-url=*)
        delete_parameter "${i}"
        GITHUB_BASE_URL=${i#*=}
      ;;
      --github-repo=*)
        delete_parameter "${i}"
        GITHUB_REPO=${i#*=}
      ;;
      --github-password=*)
        delete_parameter "${i}"
        GITHUB_PASSWD=${i#*=}
      ;;
      --github-token=*)
        delete_parameter "${i}"
        GITHUB_TOKEN=${i#*=}
      ;;
      --github-user=*)
        delete_parameter "${i}"
        GITHUB_USER=${i#*=}
      ;;
      --github-use-emoji-vote)
        delete_parameter "${i}"
        GITHUB_USE_EMOJI_VOTE=true
      ;;
    esac
  done
}


## @description this gets called when JIRA thinks this
## @description issue is just a pointer to github
## @description WARNING: Called from JIRA plugin!
function github_jira_bridge
{
  declare jsonloc=$1
  declare patchout=$2
  declare diffout=$3
  declare urlfromjira

  # shellcheck disable=SC2016
  urlfromjira=$("${AWK}" "match(\$0,\"${GITHUB_BASE_URL}/[^ ]*patch[ &\\\"]\"){url=substr(\$0,RSTART,RLENGTH-1)}
                        END{if (url) print url}" "${jsonloc}" )
  if [[ -z $urlfromjira ]]; then
    # This is currently the expected path, as github pull requests are not common
    return 1
  fi

  # we use this to prevent loops later on
  GITHUB_BRIDGED=true
  yetus_debug "github_jira_bridge: Checking url ${urlfromjira}"
  github_breakup_url "${urlfromjira}"
  github_locate_patch GH:"${GITHUB_ISSUE}" "${patchout}" "${diffout}"
}

## @description given a URL, break it up into github plugin globals
## @description this will *override* any personality or yetus defaults
## @description WARNING: Called from the Jenkins support system!
## @param url
function github_breakup_url
{
  declare url=$1
  declare count
  declare pos1
  declare pos2

  if [[ "${url}" =~ \@ ]]; then
    url=${url//:/\/}
    url=${url//git@/https://}
  fi

  url=${url%\.git}

  count=${url//[^\/]}
  count=${#count}
  if [[ ${count} -gt 4 ]]; then
    ((pos2=count-3))
    ((pos1=pos2))

    GITHUB_BASE_URL=$(echo "${url}" | cut "-f1-${pos2}" -d/)

    ((pos1=pos1+1))
    ((pos2=pos1+1))

    GITHUB_REPO=$(echo "${url}" | cut "-f${pos1}-${pos2}" -d/)

    ((pos1=pos2+2))
    unset pos2

    GITHUB_ISSUE=$(echo "${url}" | cut "-f${pos1}-${pos2}" -d/ | cut -f1 -d.)
  else
    GITHUB_BASE_URL=$(echo "${url}" | cut -f1-3 -d/)
    GITHUB_REPO=$(echo "${url}" | cut -f4- -d/)
  fi
}

## @description initalize github
function github_initialize
{
  if [[ -z "${GITHUB_REPO}" ]]; then
    GITHUB_REPO=${GITHUB_REPO_DEFAULT:-}
  fi

  if [[ -n "${GITHUB_TOKEN}" ]]; then
    GITHUB_AUTH=(-H "Authorization: token ${GITHUB_TOKEN}")
  elif [[ -n "${GITHUB_USER}"
     && -n "${GITHUB_PASSWD}" ]]; then
    GITHUB_AUTH=(-u "${GITHUB_USER}:${GITHUB_PASSWD}")
  fi

  # if the default branch hasn't been set yet, ask GitHub
  if [[ -z "${PATCH_BRANCH_DEFAULT}"  && -n "${GITHUB_REPO}" && "${OFFLINE}" == false ]]; then
    "${CURL}" --silent --fail \
          -H "Accept: application/vnd.github.v3.full+json" \
          "${GITHUB_AUTH[@]}" \
          --output "${PATCH_DIR}/github-repo.json" \
          --location \
         "${GITHUB_API_URL}/repos/${GITHUB_REPO}" \
         > /dev/null
    PATCH_BRANCH_DEFAULT=$("${GREP}" default_branch "${PATCH_DIR}/github-repo.json" | head -1 | cut -d\" -f4)
  fi

}

## @description based upon a github PR, attempt to link back to JIRA
function github_find_jira_title
{
  declare title
  declare maybe
  declare retval

  if [[ ! -f "${PATCH_DIR}/github-pull.json" ]]; then
    return 1
  fi

  title=$(${GREP} title "${PATCH_DIR}/github-pull.json" \
    | cut -f4 -d\")

  # people typically do two types:  JIRA-ISSUE: and [JIRA-ISSUE]
  # JIRA_ISSUE_RE is pretty strict so we need to chop that stuff
  # out first

  maybe=$(echo "${title}" | cut -f2 -d\[ | cut -f1 -d\])
  jira_determine_issue "${maybe}"
  retval=$?

  if [[ ${retval} == 0 ]]; then
    return 0
  fi

  maybe=$(echo "${title}" | cut -f1 -d:)
  jira_determine_issue "${maybe}"
  retval=$?

  if [[ ${retval} == 0 ]]; then
    return 0
  fi

  return 1
}

function github_determine_issue
{
  declare input=$1

  if [[ ${input} =~ ^[0-9]+$
     && -n ${GITHUB_REPO} ]]; then
    # shellcheck disable=SC2034
    ISSUE=${input}
    if [[ -z ${GITHUB_ISSUE} ]]; then
      GITHUB_ISSUE=${input}
    fi
  fi

  # if JIRA didn't call us, should we call it?
  if [[ ${GITHUB_BRIDGED} == false ]]; then
    if github_find_jira_title; then
      return 0
    fi
  fi

  if [[ -n ${GITHUB_ISSUE} ]]; then
    return 0
  fi

  return 1
}

## @description  Try to guess the branch being tested using a variety of heuristics
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success, with PATCH_BRANCH updated appropriately
## @return       1 on failure
function github_determine_branch
{
  if [[ ! -f "${PATCH_DIR}/github-pull.json" ]]; then
    return 1
  fi

  # shellcheck disable=SC2016
  PATCH_BRANCH=$("${AWK}" 'match($0,"\"ref\": \""){print $2}' "${PATCH_DIR}/github-pull.json"\
     | cut -f2 -d\"\
     | tail -1  )

  yetus_debug "Github determine branch: starting with ${PATCH_BRANCH}"

  verify_valid_branch "${PATCH_BRANCH}"
}

## @description  Given input = GH:##, download a patch to output.
## @description  Also sets GITHUB_ISSUE to the raw number.
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        input
## @param        output
## @return       0 on success
## @return       1 on failure
function github_locate_pr_patch
{
  declare input=$1
  declare patchout=$2
  declare diffout=$3
  declare apiurl

  input=${input#GH:}

  # https://github.com/your/repo/pull/##
  if [[ ${input} =~ ^${GITHUB_BASE_URL}.*/pull/[0-9]+$ ]]; then
    github_breakup_url "${input}.patch"
    input=${GITHUB_ISSUE}
  fi

  # https://github.com/your/repo/pulls/##.patch
  if [[ ${input} =~ ^${GITHUB_BASE_URL}.*patch$ ]]; then
    github_breakup_url "${input}"
    input=${GITHUB_ISSUE}
  fi

  # https://github.com/your/repo/pulls/##.diff
  if [[ ${input} =~ ^${GITHUB_BASE_URL}.*diff$ ]]; then
    github_breakup_url "${input}"
    input=${GITHUB_ISSUE}
  fi

  # if it isn't a number at this point, no idea
  # how to process
  if [[ ! ${input} =~ ^[0-9]+$ ]]; then
    yetus_debug "github: ${input} is not a pull request #"
    return 1
  fi

  # we always pull both the .patch and .diff versions
  # but set the default to be .patch so that binary files work.
  # The downside of this is that the patch files are
  # significantly larger and therefore take longer to process

  apiurl="${GITHUB_API_URL}/repos/${GITHUB_REPO}/pulls/${input}"

  # shellcheck disable=SC2034
  PATCHURL="${GITHUB_BASE_URL}/${GITHUB_REPO}/pull/${input}.patch"

  echo "GITHUB PR #${input} is being downloaded from"
  echo "${apiurl}"

  echo "  JSON data at $(date)"
  # Let's pull the PR JSON for later use
  if ! "${CURL}" --silent --fail \
          -H "Accept: application/vnd.github.v3.full+json" \
          "${GITHUB_AUTH[@]}" \
          --output "${PATCH_DIR}/github-pull.json" \
          --location \
         "${apiurl}"; then
    yetus_debug "github_locate_patch: cannot download json"
    return 1
  fi

  echo "  Patch data at $(date)"

  # the actual patch file
  if ! "${CURL}" --silent --fail \
          -H "Accept: application/vnd.github.v3.patch" \
          --output "${patchout}" \
          --location \
          "${GITHUB_AUTH[@]}" \
         "${GITHUB_API_URL}/repos/${GITHUB_REPO}/pulls/${input}"; then
    yetus_debug "github_locate_patch: not a github pull request."
    return 1
  fi

  echo "  Diff data at $(date)"
  if ! "${CURL}" --silent --fail \
          -H "Accept: application/vnd.github.v3.diff" \
          --output "${diffout}" \
          --location \
          "${GITHUB_AUTH[@]}" \
         "${apiurl}"; then
    yetus_debug "github_locate_patch: cannot download diff"
    return 1
  fi

  GITHUB_ISSUE=${input}

  # github will translate this to be #(xx) !
  add_footer_table "GITHUB PR" "${GITHUB_BASE_URL}/${GITHUB_REPO}/pull/${input}"

  return 0
}


## @description  a wrapper for github_locate_pr_patch that
## @description  that takes a (likely checkout'ed) github commit
## @description  sha and turns into the the github pr
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        input
## @param        output
## @return       0 on success
## @return       1 on failure
function github_locate_sha_patch
{
  declare input=$1
  declare patchout=$2
  declare diffout=$3
  declare gitsha
  declare number

  gitsha=${input#GHSHA:}

  # locate the PR number via GitHub API v3
  #curl https://api.github.com/search/issues?q=sha:40a7af3377d8087779bf8ad66397947b7270737a\&type:pr\&repo:apache/yetus


   # Let's pull the PR JSON for later use
  if ! "${CURL}" --silent --fail \
          -H "Accept: application/vnd.github.v3.full+json" \
          "${GITHUB_AUTH[@]}" \
          --output "${PATCH_DIR}/github-search.json" \
          --location \
         "${GITHUB_API_URL}/search/issues?q=${gitsha}&type:pr&repo:${GITHUB_REPO}"; then
    return 1
  fi

  # shellcheck disable=SC2016
  number=$("${GREP}" number "${PATCH_DIR}/github-search.json" | \
           head -1 | \
           "${AWK}" '{print $NF}')
  number=${number//\s}
  number=${number%,}

  github_locate_pr_patch "GH:${number}" "${patchout}" "${diffout}"
}


## @description  Handle the various ways to reference a github PR
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        input
## @param        output
## @return       0 on success
## @return       1 on failure
function github_locate_patch
{
  declare input=$1
  declare patchout=$2
  declare diffout=$3

  if [[ "${OFFLINE}" == true ]]; then
    yetus_debug "github_locate_patch: offline, skipping"
    return 1
  fi

  case "${input}" in
      GHSHA:*)
        github_locate_sha_patch "${input}" "${patchout}" "${diffout}"
      ;;
      *)
        github_locate_pr_patch "${input}" "${patchout}" "${diffout}"
      ;;
  esac
}

function github_linecomments
{
  declare file=$1
  declare linenum=$2
  declare column=$3
  declare plugin=$4
  shift 4
  declare text=$*

  if [[ "${ROBOTTYPE}" == 'githubactions' ]]; then
    if [[ -z "${column}" ]] || [[ "${column}" == 0 ]]; then
      echo "::error file=${file},line=${linenum}::${plugin}:${text}"
    else
      echo "::error file=${file},line=${linenum},col=${column}::${plugin}:${text}"
    fi
    return 0
  fi
}

## @description Write the contents of a file to github
## @param     filename
## @stability stable
## @audience  public
function github_write_comment
{
  declare -r commentfile=${1}
  declare retval=0
  declare restfile="${PATCH_DIR}/ghcomment.$$"

  if [[ "${OFFLINE}" == true ]]; then
    echo "Github Plugin: Running in offline, comment skipped."
    return 0
  fi

  {
    printf "{\"body\":\""
    "${SED}" -e 's,\\,\\\\,g' \
        -e 's,\",\\\",g' \
        -e 's,$,\\r\\n,g' "${commentfile}" \
    | tr -d '\n'
    echo "\"}"
  } > "${restfile}"

  if [[ "${#GITHUB_AUTH[@]}" -lt 1 ]]; then
    echo "Github Plugin: no credentials provided to write a comment."
    return 0
  fi

  "${CURL}" -X POST \
       -H "Accept: application/vnd.github.v3.full+json" \
       -H "Content-Type: application/json" \
       "${GITHUB_AUTH[@]}" \
       -d @"${restfile}" \
       --silent --location \
         "${GITHUB_API_URL}/repos/${GITHUB_REPO}/issues/${GITHUB_ISSUE}/comments" \
        >/dev/null

  retval=$?
  rm "${restfile}"
  return ${retval}
}

# @description  Print out the finished details to the Github PR
# @audience     private
# @stability    evolving
# @replaceable  no
# @param        runresult
# function github_finalreport
# {
#   declare result=$1
#   declare i
#   declare commentfile=${PATCH_DIR}/gitcommentfile.$$
#   declare comment
#   declare url
#   declare ela
#   declare subs
#   declare logfile
#   declare calctime
#   declare vote
#   declare emoji

#   rm "${commentfile}" 2>/dev/null

#   if [[ ${ROBOT} = "false"
#      || -z ${GITHUB_ISSUE} ]] ; then
#     return 0
#   fi

#   url=$(get_artifact_url)

#   big_console_header "Adding comment to Github"

#   if [[ ${result} == 0 ]]; then
#     echo ":confetti_ball: **+1 overall**" >> "${commentfile}"
#   else
#     echo ":broken_heart: **-1 overall**" >> "${commentfile}"
#   fi
#   printf '\n\n\n\n' >>  "${commentfile}"

#   i=0
#   until [[ ${i} -ge ${#TP_HEADER[@]} ]]; do
#     printf '%s\n\n' "${TP_HEADER[${i}]}" >> "${commentfile}"
#     ((i=i+1))
#   done

#   {
#     printf '\n\n'
#     echo "| Vote | Subsystem | Runtime |  Logfile | Comment |"
#     echo "|:----:|----------:|--------:|:--------:|:-------:|"
#   } >> "${commentfile}"

#   i=0
#   until [[ ${i} -ge ${#TP_VOTE_TABLE[@]} ]]; do
#     ourstring=$(echo "${TP_VOTE_TABLE[${i}]}" | tr -s ' ')
#     vote=$(echo "${ourstring}" | cut -f2 -d\| | tr -d ' ')
#     subs=$(echo "${ourstring}"  | cut -f3 -d\|)
#     ela=$(echo "${ourstring}" | cut -f4 -d\|)
#     calctime=$(clock_display "${ela}")
#     logfile=$(echo "${ourstring}" | cut -f5 -d\| | tr -d ' ')
#     comment=$(echo "${ourstring}"  | cut -f6 -d\|)

#     if [[ "${vote}" = "H" ]]; then
#       echo "|||| _${comment}_ |" >> "${commentfile}"
#       ((i=i+1))
#       continue
#     fi

#     if [[ ${GITHUB_USE_EMOJI_VOTE} == true ]]; then
#       emoji=""
#       case ${vote} in
#         1|"+1")
#           emoji="+1 :green_heart:"
#         ;;
#         -1)
#           emoji="-1 :x:"
#         ;;
#         0)
#           emoji="+0 :ok:"
#         ;;
#         -0)
#           emoji="-0 :warning:"
#         ;;
#         H)
#           # this never gets called (see above) but this is here so others know the color is taken
#           emoji=""
#         ;;
#         *)
#           # usually this should not happen but let's keep the old vote result if it happens
#           emoji=${vote}
#         ;;
#       esac
#     else
#       emoji="${vote}"
#     fi

#     if [[ -n "${logfile}" ]]; then
#       t1=${logfile/@@BASE@@/}
#       t2=$(echo "${logfile}" | "${SED}" -e "s,@@BASE@@,${url},g")
#       t2="[${t1}](${t2})"
#     else
#       t2=""
#     fi

#     printf '| %s | %s | %s | %s | %s |\n' \
#       "${emoji}" \
#       "${subs}" \
#       "${calctime}" \
#       "${t2}" \
#       "${comment}" \
#       >> "${commentfile}"

#     ((i=i+1))
#   done

#   if [[ ${#TP_TEST_TABLE[@]} -gt 0 ]]; then
#     {
#       printf '\n\n'
#       echo "| Reason | Tests |"
#       echo "|-------:|:------|"
#     } >> "${commentfile}"
#     i=0
#     until [[ ${i} -ge ${#TP_TEST_TABLE[@]} ]]; do
#       echo "${TP_TEST_TABLE[${i}]}" >> "${commentfile}"
#       ((i=i+1))
#     done
#   fi

#   {
#     printf '\n\n'
#     echo "| Subsystem | Report/Notes |"
#     echo "|----------:|:-------------|"
#   } >> "${commentfile}"

#   i=0
#   until [[ $i -ge ${#TP_FOOTER_TABLE[@]} ]]; do
#     comment=$(echo "${TP_FOOTER_TABLE[${i}]}" | "${SED}" -e "s,@@BASE@@,${url},g")
#     printf '%s\n' "${comment}" >> "${commentfile}"
#     ((i=i+1))
#   done
#   printf '\n\nThis message was automatically generated.\n\n' >> "${commentfile}"

#   github_write_comment "${commentfile}"
# }

## @description  Write a github status
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        runresult
function github_status_write()
{
  declare filename=$1
  declare retval=0

  if [[ "${#GITHUB_AUTH[@]}" -lt 1 ]]; then
    echo "Github Plugin: no credentials provided to write a status."
    return 0
  fi

  "${CURL}" --silent --fail -X POST \
    -H "Accept: application/vnd.github.v3.full+json" \
    -H "Content-Type: application/json" \
    "${GITHUB_AUTH[@]}" \
    -d @"${filename}" \
    --location \
    "${GITHUB_API_URL}/repos/${GITHUB_REPO}/statuses/${GIT_BRANCH_SHA}" \
    > /dev/null

  retval=$?
  if [[ ${retval} -gt 0 ]]; then
    echo "githubstatus-report: Failed to write status. Maybe the credential does not have write access to repo:status."
  fi
  return ${retval}
}

## @description  Print out the finished details to the Github PR
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        runresult
function github_finalreport
{
  declare result=$1
  declare tempfile="${PATCH_DIR}/ghstatus.$$.${RANDOM}"
  declare warnings=false
  declare foundlogs=false
  declare url
  declare logurl
  declare comment
  declare url
  declare subs
  declare logfile
  declare vote
  declare ourstring
  declare -i i=0
  declare header

  big_console_header "Adding GitHub Statuses"

  if [[ "${#GITHUB_AUTH[@]}" -lt 1 ]]; then
    echo "Github Plugin: no credentials provided to write a status."
    return 0
  fi

  if [[ -z "${GIT_BRANCH_SHA}" ]]; then
    echo "Unknown GIT_BRANCH_SHA defined. Skipping."
    return 0
  fi

  url=$(get_artifact_url)

  if [[ "${ROBOTTYPE}" ]]; then
    header="Apache Yetus(${ROBOTTYPE})"
  else
    header="Apache Yetus"
  fi

  # Customize the message based upon type of passing:
  # - if there were no warnings, then just put a single message
  # - if there were warningss, but no logs, then just mention warnings
  # - if there were warnings and logs, handle in the next section
  if [[ "${result}" == 0 ]]; then
    i=0
    until [[ ${i} -eq ${#TP_VOTE_TABLE[@]} ]]; do
      ourstring=$(echo "${TP_VOTE_TABLE[${i}]}" | tr -s ' ')
      vote=$(echo "${ourstring}" | cut -f2 -d\| | tr -d ' ')

      if [[ "${vote}" == "-0" ]]; then
        warnings=true
        logfile=$(echo "${ourstring}" | cut -f5 -d\| | tr -d ' ')

        if [[ -n "${logfile}" ]]; then
          foundlogs=true
          break
        fi
      fi
      ((i=i+1))
    done

    # did not find any logs, so just give a simple success status
    if [[ ${foundlogs} == false ]]; then
      if [[ ${warnings} == false ]]; then
        # build our REST post
        {
          echo "{\"state\": \"success\", "
          echo "\"target_url\": \"${BUILD_URL}${BUILD_URL_CONSOLE}\","
          echo "\"description\": \"passed\","
          echo "\"context\":\"${header}\"}"
        } > "${tempfile}"
      elif [[ ${warnings} == true ]]; then
        # build our REST post
        {
          echo "{\"state\": \"success\", "
          echo "\"target_url\": \"${BUILD_URL}${BUILD_URL_CONSOLE}\","
          echo "\"description\": \"passed with warnings\","
          echo "\"context\":\"${header}\"}"
        } > "${tempfile}"
      fi
      github_status_write "${tempfile}"
      rm "${tempfile}"
      return 0
    fi
  fi

  # from here on, success w/logs or failure.
  # give a separate status for each:
  # - failure
  # - failure w/log
  # - successs w/warning log

  i=0
  until [[ ${i} -eq ${#TP_VOTE_TABLE[@]} ]]; do
    ourstring=$(echo "${TP_VOTE_TABLE[${i}]}" | tr -s ' ')
    vote=$(echo "${ourstring}" | cut -f2 -d\| | tr -d ' ')
    subs=$(echo "${ourstring}"  | cut -f3 -d\|)
    logfile=$(echo "${ourstring}" | cut -f5 -d\| | tr -d ' ')
    comment=$(echo "${ourstring}"  | cut -f6 -d\|)

    if [[ "${vote}" = "H" ]]; then
      ((i=i+1))
      continue
    fi

    # GitHub needs more statuses to cover everything yetus does :(
    case ${vote} in
      -1)
        status="error"
      ;;
      *)
        status="success"
      ;;
    esac

    logurl=${BUILD_URL}${BUILD_URL_CONSOLE}
    if [[ "${url}" =~ ^http ]]; then
      if [[ -n "${logfile}" ]]; then
        logurl=$(echo "${logfile}" | "${SED}" -e "s,@@BASE@@,${url},g")
      fi
    fi

    if [[ ${status} == "success" && -n "${logfile}" ]]; then
      {
        echo "{\"state\": \"${status}\", "
        echo "\"target_url\": \"${logurl}\","
        echo "\"description\": \"${comment}\","
        echo "\"context\":\"${header} warning: ${subs}\"}"
      } > "${tempfile}"
      github_status_write "${tempfile}"
      rm "${tempfile}"
    elif [[ ${status} == "error" ]]; then
      {
        echo "{\"state\": \"${status}\", "
        echo "\"target_url\": \"${logurl}\","
        echo "\"description\": \"${comment}\","
        echo "\"context\":\"${header} error: ${subs}\"}"
      } > "${tempfile}"
      github_status_write "${tempfile}"
      rm "${tempfile}"
    fi
    ((i=i+1))
  done
}