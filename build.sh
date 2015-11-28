#!/bin/bash -e
#
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
#
# Temporary script for building tarballs. See YETUS-125 to help
# create a more sustainable build system.
#
# Pass --release to get release checks
#
# Presumes you have
#   * maven 3.2.0+
#   * jdk 1.7+ (1.7 in --release)
#   * ruby + gems needed to run middleman
YETUS_VERSION=$(cat VERSION)
RAT_DOWNLOAD_URL=https://repo1.maven.org/maven2/org/apache/rat/apache-rat/0.11/apache-rat-0.11.jar

release=false
offline=false
for arg in "$@"; do
  if [ "--release" = "${arg}" ]; then
    release=true
  elif [ "--offline" = "${arg}" ]; then
    offline=true
  fi
done

echo "working on version '${YETUS_VERSION}'"
mkdir -p target

if [ "${offline}" != "true" ]; then
  JIRA_VERSION="${YETUS_VERSION%%-SNAPSHOT}"
  echo "generating release docs."
  # working around YETUS-214
  # no --license flag, YETUS-215
  rn_out=$(cd target && \
           ../release-doc-maker/releasedocmaker.py --lint \
                                                   --project YETUS "--version=${JIRA_VERSION}" \
                                                   --projecttitle="Apache Yetus" --usetoday && \
           mv "${JIRA_VERSION}/RELEASENOTES.${JIRA_VERSION}.md" RELEASENOTES.md && \
           mv "${JIRA_VERSION}/CHANGES.${JIRA_VERSION}.md" CHANGES.md \
          )
  echo "${rn_out}"
else
  echo "in offline mode, skipping release notes."
fi

MAVEN_ARGS=()
if [ "${offline}" = "true" ]; then
  MAVEN_ARGS=("${MAVEN_ARGS[@]}" --offline)
fi

if [ "${release}" = "true" ]; then
  MAVEN_ARGS=("${MAVEN_ARGS[@]}" -Papache-release)
  echo "hard reseting working directory."
  git reset --hard HEAD

  if [ ! -f target/rat.jar ]; then
    if [ "${offline}" != "true" ]; then
      echo "downloading rat jar file to '$(pwd)/target/'"
      curl -o target/rat.jar "${RAT_DOWNLOAD_URL}"
    else
      echo "in offline mode, can't retrieve rat jar. will skip license check."
    fi
  fi
  echo "creating source tarball at '$(pwd)/target/'"
  rm "target/yetus-${YETUS_VERSION}-src".tar* 2>/dev/null || true
  current=$(basename "$(pwd)")
  tar -s "/${current}/yetus-${YETUS_VERSION}/" -C ../ -cf "target/yetus-${YETUS_VERSION}-src.tar" --exclude '*/target/*' --exclude '*/publish/*' --exclude '*/.git/*' "${current}"
  tar -s "/target/yetus-${YETUS_VERSION}/" -rf "target/yetus-${YETUS_VERSION}-src.tar" target/RELEASENOTES.md target/CHANGES.md
  gzip "target/yetus-${YETUS_VERSION}-src.tar"
fi

echo "running maven builds for java components"
# build java components
mvn "${MAVEN_ARGS[@]}" install --file yetus-project/pom.xml
mvn "${MAVEN_ARGS[@]}" -Pinclude-jdiff-module install javadoc:aggregate --file audience-annotations-component/pom.xml

echo "building documentation"
# build docs after javadocs
docs_out=$(cd asf-site-src && bundle exec middleman build)
echo "${docs_out}"

bin_tarball="target/bin-dir/yetus-${YETUS_VERSION}"
echo "creating staging area for convenience binary at '$(pwd)/${bin_tarball}'"
rm -rf "${bin_tarball}" 2>/dev/null || true
mkdir -p "${bin_tarball}"
cp LICENSE NOTICE target/RELEASENOTES.md target/CHANGES.md "${bin_tarball}"
cp -r asf-site-src/publish/documentation/in-progress "${bin_tarball}/docs"

mkdir -p "${bin_tarball}/lib"
cp VERSION "${bin_tarball}/lib/"

mkdir -p "${bin_tarball}/lib/yetus-project"
cp yetus-project/pom.xml "${bin_tarball}/lib/yetus-project/yetus-project-${YETUS_VERSION}.pom"

mkdir -p "${bin_tarball}/lib/audience-annotations"
cp audience-annotations-component/audience-annotations/target/audience-annotations-*.jar \
   audience-annotations-component/audience-annotations-jdiff/target/audience-annotations-jdiff-*.jar \
   "${bin_tarball}/lib/audience-annotations/"

cp -r shelldocs "${bin_tarball}/lib/"

cp -r release-doc-maker "${bin_tarball}/lib/"

cp -r precommit "${bin_tarball}/lib/"

mkdir -p "${bin_tarball}/bin"

for utility in shelldocs/shelldocs.py release-doc-maker/releasedocmaker.py \
               precommit/smart-apply-patch.sh precommit/test-patch.sh
do
  wrapper=${utility##*/}
  wrapper=${wrapper%.*}
  cat >"${bin_tarball}/bin/${wrapper}" <<EOF
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

"\$(dirname "\$(dirname "\${BASH_SOURCE-0}")")/lib/${utility}" "\${@}"
EOF
  chmod +x "${bin_tarball}/bin/${wrapper}"
done

bin_file="target/yetus-${YETUS_VERSION}-bin.tar.gz"
echo "creating convenience binary in '$(pwd)/target'"
rm "${bin_file}" 2>/dev/null || true
tar -C "$(dirname "${bin_tarball}")" -czf "${bin_file}" "$(basename "${bin_tarball}")"

if [ "${release}" = "true" ] && [ -f target/rat.jar ]; then
  echo "checking asf licensing requirements for source tarball '$(pwd)/target/yetus-${YETUS_VERSION}-src.tar.gz'."
  rm -rf target/source-unpack 2>/dev/null || true
  mkdir target/source-unpack
  tar -C target/source-unpack -xzf "target/yetus-${YETUS_VERSION}-src.tar.gz"
  java -jar target/rat.jar -E .rat-excludes -d target/source-unpack

  echo "checking asf licensing requirements for convenience binary '$(pwd)/${bin_file}'."
  rm -rf target/bin-unpack 2>/dev/null || true
  mkdir target/bin-unpack
  tar -C target/bin-unpack -xzf "${bin_file}"
  java -jar target/rat.jar -E .rat-excludes -d target/bin-unpack
fi
echo "All Done!"
echo "Find your output at:"
if [ "${release}" = "true" ] && [ -f "target/yetus-${YETUS_VERSION}-src.tar.gz" ]; then
  echo "    $(pwd)/target/yetus-${YETUS_VERSION}-src.tar.gz"
fi
if [ -f "${bin_file}" ]; then
  echo "    $(pwd)/${bin_file}"
fi
