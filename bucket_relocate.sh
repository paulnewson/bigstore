#!/bin/bash
# Copyright 2013 Google Inc. All Rights Reserved.
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

function Usage {
  cat << EOF
bucket_relocate - relocates buckets in Google Cloud Storage

This script can be used to migrate one or more buckets to a different
location and/or storage class. It operates in two stages: In stage 1, a
temporary bucket is created in the new location/storage class corresponding
to each bucket being migrated, and data are copied from the original to the
new bucket(s). In stage 2 any newly created data are copied from the original
to the temporary bucket(s), the original buckets are deleted and recreated in
the new location/storage class, data are copied-in-the-cloud from the
temporary to the re-created bucket(s), and the temporary bucket(s) deleted.
Stage 1 can take a long time (depending on how much data you have and how
fast your network connection is); stage 2 should run quickly. You should
ensure no reads or writes are occurring to your bucket during the brief period
while stage 2 runs.

Starting conditions:
You must have at least version 4.0 of bash and version 3.30 of gsutil
installed, with credentials that have FULL_CONTROL access to the bucket and
READ access to all objects in the bucket. If this script is run by a user that
lacks these permissions the script may fail part-way through. Should this
happen, the permissions will need to be fixed and the script can be rerun.

Caveats:
1) If an object is deleted from the original bucket after it has been processed
   in stage 1, that object will not be deleted during stage 2.
2) If an object is overwritten after it has been processed in stage 1, that
   change will not be re-copied during stage 2.
3) Object change notification configuration isn't preserved by this migration
   script.
4) The script expects that the identity under which this script is run can read
   and write all the buckets and objects which need to be migrated.

If your application overwrites or deletes objects, we recommend disabling all
writes while running both stages.

Usage:
   bucket_relocate.sh STAGE [OPTION]... bucket...

Examples:
   bucket_relocate.sh -2 gs://mybucket

STAGE
   The stage determines what stage should be executed:
   -1            run stage 1 - during this time users can still add objects
                 to the bucket. These new objects will be copied in stage 2.
   -2            run stage 2 - during this stage, no users should be adding
                 or modifying any content in the bucket.
   -A            run stage 1 and stage 2 back-to-back - use this option if you
                 are guaranteed that no users will be making changes to the
                 bucket throughout the entire process.
    Please note that during both stages users should not be deleting or
    overwriting existing objects as these changes will not be detected.

OPTIONS
   -?            show this usage information.

   -c <class>    sets the storage class of the destination bucket.
                 Example storage classes:
                 S - Standard (default)
                 DRA - Durable Reduced Availability storage.

   -l <location> sets the location of the destination bucket.
                 Example locations:
                 US - United States (default)
                 EU - European Union

    -v           Verify that the credentials being used have write access to all
                 buckets being migrated and read access to all objects within
                 those buckets.

Multiple buckets can be specified if more than one bucket needs to be
relocated. This can be done as follows:

   bucket_relocate.sh -A gs://bucket01 gs://bucket02 gs://bucket03

To relocate all buckets in a given project, you could do the following:

   gsutil ls -p project-id | xargs bucket_relocate.sh -A -c DRA -l EU

EOF
}

buckets=()
tempbuckets=()
stage=-1
location=''
class=''
manifest=/tmp/bucket-relocate-manifest.log
steplog=/tmp/bucket-relocate-step.log
debugout=/tmp/bucket-relocate-debug.log
extra_verification=false

# Keep track of the step we're at with each bucket using an associative array
# and a file. NOTE: Associative arrays require Bash 4.0
if [ ${BASH_VERSION:0:1} -lt 4 ]; then
  echo "This script requires bash version 4 or higher." 1>&2;
  exit 1
fi
declare -A steps
if [ ! -f $steplog ]; then
  touch $steplog
fi

function EchoErr() {
  # echo the function parameters to stderr.
  echo "$@" 1>&2;
  echo "ERROR -- $1" >> $debugout
}

function LastStep() {
  exec 3<$steplog
  while read -u3 p; do
    IFS=',' read -ra VARS <<< "$p"
    vars_step=${VARS[0]}
    vars_bucket=${VARS[1]}
    steps[${vars_bucket}]=${vars_step}
  done
  s=${steps[$1]}
  if [ "$s" == '' ]; then
    echo "0"
  else
    echo $s
  fi
}

function LogStepStart() {
    echo $1
    echo "START -- $1" >> $debugout
}

function LogStepEnd() {
    echo $1 >> $steplog
    echo "END -- $1" >> $debugout
}

function BucketExists() {
  $gsutil getversioning $1 &>> $debugout
  if [ $? -eq 0 ]; then
    echo true
  else
    echo false
  fi
}


# Parse command line arguments
while getopts ":?12Ac:l:v" opt; do
  case $opt in
    A)
      # Using -A will make stage 1 and 2 run back-to-back
      if [ $stage != -1 ]; then
        EchoErr "Only a single stage can be set."
        exit 1
      fi
      stage=0
      ;;
    1)
      if [ $stage != -1 ]; then
        EchoErr "Only a single stage can be set."
        exit 1
      fi
      stage=1
      ;;
    2)
      if [ $stage != -1 ]; then
        EchoErr "Only a single stage can be set."
        exit 1
      fi
      stage=2
      ;;
    c)
      # Sets the storage class, such as S (for Standard) or DRA (for Durable
      # Reduced Availability)
      if [ "$class" != '' ]; then
        EchoErr "Only a single class can be set."
        exit 1
      fi
      class=$OPTARG
      ;;
    l)
      # Sets the location of the bucket. For example: US or EU
      if [ "$location" != '' ]; then
        EchoErr "Only a single location can be set."
        exit 1
      fi
      location=$OPTARG
      ;;
    v)
      extra_verification=true
      ;;
    ?)
      Usage
      exit 0
      ;;
    \?)
      EchoErr "Invalid option: -$OPTARG"
      exit 1
      ;;
  esac
done

shift $(($OPTIND - 1))
while test $# -gt 0; do
  # Buckets must have the gs:// prefix.
  if [ ${#1} -lt 6 ] || [ "${1:0:5}" != 'gs://' ]; then
    EchoErr "$1 is not a supported bucket name. Bucket names must start with gs://"
    exit 1
  fi
  buckets=("${buckets[@]}" $1)
  tempbuckets=("${tempbuckets[@]}" $1-relocate)
  shift
done

num_buckets=${#buckets[@]}
if [ $num_buckets -le 0 ]; then
  Usage
  exit 1
fi
if [ $stage == -1 ]; then
  EchoErr "Stage not specified. Please specify either -A (for all), -1, or -2."
  exit 1
fi
if [[ "$location" == '' ]]; then
  location='US'
fi
if [[ "$class" == '' ]]; then
  class='S'
fi

# Display a summary of the options
if [ $stage == 0 ]; then
  echo "Stage:         All stages"
else
  echo "Stage:         $stage"
fi
echo "Location:      $location"
echo "Storage class: $class"
echo "Bucket(s):     ${buckets[@]}"

# Check for prerequisites
# 1) Check to see if gsutil is installed
gsutil=`which gsutil`
if [ "$gsutil" == '' ]; then
  EchoErr "gsutil was not found. Please install it from https://developers.google.com/storage/docs/gsutil_install"
  exit 1
fi

# 2) Check if gsutil is configured correctly. Get the first bucket from a
#    gsutil ls. We can safely assume there is at least one bucket otherwise
#    we wouldn't be running this script.
test_bucket=`$gsutil ls | head -1`
if [ "$test_bucket" == '' ]; then
  EchoErr "gsutil does not seem to be configured. Please run gsutil config."
  exit 1
fi

# 3) Checking gsutil version
gsutil_version=`$gsutil version`
if [ $? -ne 0 ]; then
  EchoErr "Failed to get version information for gsutil."
  exit 1
fi
major=${gsutil_version:15:1}
minor=${gsutil_version:17:2}
if [ $major -lt 3 ] || ( [ $major -eq 3 ] && [ $minor -lt 30 ] ); then
  EchoErr "Incorrect version of gsutil. Need 3.30 or greater. Have: $gsutil_version"
  exit 1
fi

function Stage1 {
  echo 'Now executing stage 1...'

  # For each bucket, do some verifications:
  for i in ${!buckets[*]}; do
    bucket=${buckets[$i]}
    src=$bucket

    # STEP 1: Verify that the source bucket exists.
    if [ `LastStep "$src"` -eq 0 ]; then
      LogStepStart "Step 1: ($src) - verify the bucket exists."
      exists=`BucketExists $src`
      if ! $exists; then
        EchoErr "Validation check failed: The specified bucket does not exist: $bucket"
        exit 1
      fi
      LogStepEnd "1,$src"
    fi

    # STEP 2: Verify that we can read all the objects.
    if [ `LastStep "$src"` -eq 1 ]; then
      if $extra_verification ; then
        LogStepStart "Step 2: ($src) - checking object permissions. This may take a while..."
        $gsutil ls -L $src/** &>> $debugout
        if [ $? -ne 0 ]; then
          EchoErr "Validation failed: Access denied reading an object from $src."
          EchoErr "Check the log file ($debugout) for more details."
          exit 1
        fi
        LogStepEnd "2,$src"
      else
        LogStepStart "Step 2: ($src) - Skipping object permissions check."
        LogStepEnd "2,$src"
      fi
    fi

    # STEP 3: Verify WRITE access to the bucket.
    if [ `LastStep "$src"` -eq 2 ]; then
      LogStepStart "Step 3: ($src) - checking write permissions."
      random_name="relocate_check_`tr -dc "[:alpha:]" < /dev/urandom | head -c 60`"
      echo 'relocate access check' | gsutil cp - $src/$random_name &>> $debugout
      if [ $? -ne 0 ]; then
        EchoErr "Validation check failed: Access denied writing to $src."
        exit 1
      fi

      # Remove the temporary file.
      gsutil rm $src/$random_name &>> $debugout
      if [ $? -ne 0 ]; then
        EchoErr "Validation failed: Could not delete temporary object: $src/$random_name"
        EchoErr "Check the log file ($debugout) for more details."
        exit 1
      fi
      LogStepEnd "3,$src"
    fi
  done

  # For each bucket, do the processing...
  for i in ${!buckets[*]}; do
    src=${buckets[$i]}
    dst=${tempbuckets[$i]}

    # STEP 4: verify that the bucket does not yet exist and create it in the
    # correct location with the correct storage class
    if [ `LastStep "$src"` -eq 3 ]; then
      LogStepStart "Step 4: ($src) - creating temporary bucket ($dst)."
      dst_exists=`BucketExists $dst`
      if $dst_exists; then
        EchoErr "The bucket $dst already exists."
        exit 1
      else
        $gsutil mb -l $location -c $class $dst
        if [ $? -ne 0 ]; then
          EchoErr "Failed to create the bucket: $dst"
          exit 1
        fi
      fi
      LogStepEnd "4,$src"
    fi

    # STEP 5: Copy the objects from the source bucket to the temp bucket
    if [ `LastStep "$src"` -eq 4 ]; then
      LogStepStart "Step 5: ($src) - copying objects from source to temporary bucket ($dst)."
      $gsutil -m cp -R -p -L $manifest -D $src/* $dst/
      if [ $? -ne 0 ]; then
        EchoErr "Failed to copy objects from $src to $dst."
        exit 1
      fi
      LogStepEnd "5,$src"
    fi


    # STEP 6: Backup the metadata for the bucket
    if [ `LastStep "$src"` -eq 5 ]; then
      short_name=${src:5}
      LogStepStart "Step 6: ($src) - backing up the bucket metadata."
      $gsutil getdefacl $src > /tmp/bucket-relocate-defacl-for-$short_name
      if [ $? -ne 0 ]; then
        EchoErr "Failed to backup the default ACL configuration for $src"
        exit 1
      fi
      $gsutil getwebcfg $src > /tmp/bucket-relocate-webcfg-for-$short_name
      if [ $? -ne 0 ]; then
        EchoErr "Failed to backup the web configuration for $src"
        exit 1
      fi
      $gsutil getlogging $src > /tmp/bucket-relocate-logging-for-$short_name
      if [ $? -ne 0 ]; then
        EchoErr "Failed to backup the logging configuration for $src"
        exit 1
      fi
      $gsutil getcors $src > /tmp/bucket-relocate-cors-for-$short_name
      if [ $? -ne 0 ]; then
        EchoErr "Failed to backup the CORS configuration for $src"
        exit 1
      fi
      $gsutil getversioning $src > /tmp/bucket-relocate-vers-for-$short_name
      if [ $? -ne 0 ]; then
        EchoErr "Failed to backup the versioning configuration for $src"
        exit 1
      fi
      LogStepEnd "6,$src"
    fi
  done

  if [ $stage == 1 ]; then
    # Only show this message if we aren't running both stages back-to-back.
    echo "Stage 1 complete. Please ensure no reads or writes are occurring to your bucket(s) and then run stage 2."
  fi
}

function Stage2 {
  echo 'Now executing stage 2...'

  # Make sure all the buckets are at least at step #5
  for i in ${!buckets[*]}; do
    src=${buckets[$i]}
    dst=${tempbuckets[$i]}

    if [ `LastStep "$src"` -lt 6 ]; then
      EchoErr "Relocation for bucket $src did not complete stage 1. Please rerun stage 1 for this bucket."
      exit 1
    fi
  done

  # For each bucket, do the processing...
  for i in ${!buckets[*]}; do
    src=${buckets[$i]}
    dst=${tempbuckets[$i]}

    # Catch up with any new files.
    if [ `LastStep "$src"` -eq 6 ]; then
      LogStepStart "Step 7: ($src) - catching up any new objects that weren't copied."
      $gsutil -m cp -R -p -L $manifest -D $src/* $dst/
      if [ $? -ne 0 ]; then
        EchoErr "Failed to copy any new objects from $src to $dst"
        exit 1
      fi
      LogStepEnd "7,$src"
    fi

    # Remove the old src bucket
    if [ `LastStep "$src"` -eq 7 ]; then
      LogStepStart "Step 8: ($src) - removing objects in source bucket."
      $gsutil -m rm -Ra $src/*
      if [ $? -ne 0 ]; then
        EchoErr "Failed to remove the objects in $src"
        exit 1
      fi
      LogStepEnd "8,$src"
    fi

    if [ `LastStep "$src"` -eq 8 ]; then
      LogStepStart "Step 9: ($src) - removing source bucket."
      $gsutil rb $src
      if [ $? -ne 0 ]; then
        EchoErr "Failed to remove the bucket: $src"
        exit 1
      fi
      LogStepEnd "9,$src"
    fi

    if [ `LastStep "$src"` -eq 9 ]; then
      LogStepStart "Step 10: ($src) - recreating original bucket."
      $gsutil mb -l $location -c $class $src
      if [ $? -ne 0 ]; then
        EchoErr "Failed to recreate the bucket: $src"
        exit 1
      fi
      LogStepEnd "10,$src"
    fi

    if [ `LastStep "$src"` -eq 10 ]; then
      short_name=${src:5}
      LogStepStart "Step 11: ($src) - restoring the bucket metadata."

      # defacl
      $gsutil setdefacl /tmp/bucket-relocate-defacl-for-$short_name $src
      if [ $? -ne 0 ]; then
        EchoErr "Failed to set the default ACL configuration on $src"
        exit 1
      fi

      # webcfg
      page_suffix=`cat /tmp/bucket-relocate-webcfg-for-$short_name |\
          grep -o "<MainPageSuffix>.*</MainPageSuffix>" |\
          sed -e 's/<MainPageSuffix>//g' -e 's/<\/MainPageSuffix>//g'`
      if [ "$page_suffix" != '' ]; then page_suffix="-m $page_suffix"; fi
      error_page=`cat /tmp/bucket-relocate-webcfg-for-$short_name |\
          grep -o "<NotFoundPage>.*</NotFoundPage>" |\
          sed -e 's/<NotFoundPage>//g' -e 's/<\/NotFoundPage>//g'`
      if [ "$error_page" != '' ]; then error_page="-e $error_page"; fi
      $gsutil setwebcfg $page_suffix $error_page $src
      if [ $? -ne 0 ]; then
        EchoErr "Failed to set the website configuration on $src"
        exit 1
      fi

      # logging
      log_bucket=`cat /tmp/bucket-relocate-webcfg-for-$short_name |\
          grep -o "<LogBucket>.*</LogBucket>" |\
          sed -e 's/<LogBucket>//g' -e 's/<\/LogBucket>//g'`
      if [ "$log_bucket" != '' ]; then log_bucket="-b $log_bucket"; fi
      log_prefix=`cat /tmp/bucket-relocate-webcfg-for-$short_name |\
          grep -o "<LogObjectPrefix>.*</LogObjectPrefix>" |\
          sed -e 's/<LogObjectPrefix>//g' -e 's/<\/LogObjectPrefix>//g'`
      if [ "$log_prefix" != '' ]; then log_prefix="-o $log_prefix"; fi
      if [ "$log_prefix" != '' ] && [ "$log_bucket" != '' ]; then
        $gsutil enablelogging $log_bucket $log_prefix $src
        if [ $? -ne 0 ]; then
          EchoErr "Failed to set the logging configuration on $src"
          exit 1
        fi
      fi

      # cors
      $gsutil setcors /tmp/bucket-relocate-cors-for-$short_name $src
      if [ $? -ne 0 ]; then
        EchoErr "Failed to set the CORS configuration on $src"
        exit 1
      fi

      # versioning
      versioning=`cat /tmp/bucket-relocate-vers-for-$short_name | head -1`
      vpos=$((${#src} + 2))
      versioning=${versioning:vpos}
      if [ "$versioning" == 'Enabled' ]; then
        $gsutil setversioning on $src
        if [ $? -ne 0 ]; then
          EchoErr "Failed to set the versioning configuration on $src"
          exit 1
        fi
      fi

      LogStepEnd "11,$src"
    fi

    if [ `LastStep "$src"` -eq 11 ]; then
      LogStepStart "Step 12: ($src) - copying all objects back to original bucket."
      $gsutil -m cp -Rp $dst/* $src/
      if [ $? -ne 0 ]; then
        EchoErr "Failed to copy the objects back to the original bucket: $src"
        exit 1
      fi
      LogStepEnd "12,$src"
    fi

    if [ `LastStep "$src"` -eq 12 ]; then
      LogStepStart "Step 13: ($src) - delete the objects in the temporary bucket ($dst)."
      $gsutil -m rm -R $dst/*
      if [ $? -ne 0 ]; then
        EchoErr "Failed to delete the objects from the temporary bucket:  $dst"
        exit 1
      fi
      LogStepEnd "13,$src"
    fi

    if [ `LastStep "$src"` -eq 13 ]; then
      LogStepStart "Step 14: ($src) - delete the temporary bucket ($dst)."
      $gsutil rb $dst
      if [ $? -ne 0 ]; then
        EchoErr "Failed to delete the temporary bucket:  $dst"
        exit 1
      fi
      LogStepEnd "14,$src"
    fi

    if [ `LastStep "$src"` -eq 14 ]; then
      LogStepStart "($src): Completed."
    fi

  done
}

if [ $stage == 0 ]; then
  Stage1
  Stage2
elif [ $stage == 1 ]; then
  Stage1
elif [ $stage == 2 ]; then
  Stage2
fi


