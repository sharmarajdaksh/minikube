#!/bin/bash

# Copyright 2021 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Creates a comment on the provided PR number, using the provided gopogh summary
# to list out the flake rates of all failing tests.
# Example usage: ./report_flakes.sh 11602 gopogh.json Docker_Linux

set -eu -o pipefail

if [ "$#" -ne 3 ]; then
  echo "Wrong number of arguments. Usage: report_flakes.sh <PR number> <gopogh_summary.json> <environment>" 1>&2
  exit 1
fi

PR_NUMBER=$1
SUMMARY_DATA=$2
ENVIRONMENT=$3

# To prevent having a super-long comment, add a maximum number of tests to report.
MAX_REPORTED_TESTS=30

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

TMP_DATA=$(mktemp)
# 1) Process the data in the gopogh summary.
# 2) Filter tests to only include failed tests on the environment (and only get their names).
# 3) Sort the names of the tests.
# 4) Store in file $TMP_DATA.
< "$SUMMARY_DATA" $DIR/process_data.sh \
  | sed -n -r -e "s/[0-9a-f]*,[0-9-]*,$ENVIRONMENT,([a-zA-Z\/_-]*),Failed,[.0-9]*/\1/p" \
  | sort \
  > "$TMP_DATA"

# Download the precomputed flake rates from the GCS bucket into file $TMP_FLAKE_RATES.
TMP_FLAKE_RATES=$(mktemp)
gsutil cp gs://minikube-flake-rate/flake_rates.csv "$TMP_FLAKE_RATES"

TMP_FAILED_RATES="$TMP_FLAKE_RATES\_filtered"
# 1) Parse/filter the flake rates to only include the test name and flake rates for environment.
# 2) Sort the flake rates based on test name.
# 3) Join the flake rates with the failing tests to only get flake rates of failing tests.
# 4) Sort failed test flake rates based on the flakiness of that test - stable tests should be first on the list.
# 5) Store in file $TMP_FAILED_RATES.
< "$TMP_FLAKE_RATES" sed -n -r -e "s/$ENVIRONMENT,([a-zA-Z\/_-]*),([.0-9]*),[.0-9]*/\1,\2/p" \
  | sort -t, -k1,1 \
  | join -t , -j 1 "$TMP_DATA" - \
  | sort -g -t, -k2,2 \
  > "$TMP_FAILED_RATES"

FAILED_RATES_LINES=$(wc -l < "$TMP_FAILED_RATES")
if [[ "$FAILED_RATES_LINES" -eq 0 ]]; then
  echo "No failed tests! Aborting without commenting..." 1>&2
  exit 0
fi

# Create the comment template.
TMP_COMMENT=$(mktemp)
printf "These are the flake rates of all failed tests on %s.\n|Failed Tests|Flake Rate (%%)|\n|---|---|\n" "$ENVIRONMENT" > "$TMP_COMMENT"
# 1) Get the first $MAX_REPORTED_TESTS lines.
# 2) Print a row in the table with the test name, flake rate, and a link to the flake chart for that test.
# 3) Append these rows to file $TMP_COMMENT.
< "$TMP_FAILED_RATES" head -n $MAX_REPORTED_TESTS \
  | sed -n -r -e "s/([a-zA-Z\/_-]*),([.0-9]*)/|\1|\2 ([chart](https:\/\/storage.googleapis.com\/minikube-flake-rate\/flake_chart.html?env=$ENVIRONMENT\&test=\1))|/p" \
  >> "$TMP_COMMENT"

# If there are too many failing tests, add an extra row explaining this, and a message after the table.
if [[ "$FAILED_RATES_LINES" -gt 30 ]]; then
  printf "|More tests...|Continued...|\n\nToo many tests failed - See test logs for more details." >> "$TMP_COMMENT"
fi

# install gh if not present
$DIR/../installers/check_install_gh.sh

gh pr comment "https://github.com/kubernetes/minikube/pull/$PR_NUMBER" --body "$(cat $TMP_COMMENT)"
