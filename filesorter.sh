#!/bin/bash

###############################################################################
#                                                                             #
## REQUIRED ADDITIONAL PACKAGES:                                             ##
##                              inotify-tools, uvscan                        ##
#                                                                             #
##===========================================================================##
#                                                                             #
# CHANGELOG:                                                                  #
#                                                                             #
# 13 Apr 2017 - JDB - Created the script to virus scan files and move files   #
#                     which meet certain criteria to destination directories  #
#                     specified in the config file located in the same dir.   #
#                                                                             #
###############################################################################

# Ensure undefined variables will not cause a problem
set -u

# Source the config file (in the same directory) to get the destination
# directory and log location
. filesorter.conf

# Find any files that may have been written while this script was halted for any reason
# If any are found, sleep for one second and touch them in the background
# (This generates a "close_write' state on the files, and gives the 
# 'inotifywait' loop below time to start so they can be parsed correctly).

for i in $(find $sourcedir -type f); do
  staledir=$(echo $i | awk 'BEGIN{FS=OFS="/"}{NF--; print}')
  stalefile=$(echo $i | awk -F'/' '{print $NF}')
  sleep 1 && touch $staledir/$stalefile &
done

# Don't run if another instance is already running:
if ps -eaf | grep "inotifywait" | grep -v "grep" | grep -q "$sourcedir"; then
  exit
fi

# Monitor for files being written
# Start an endless loop
while true; do

# If the sourcedir exists then watch for any "close_write" statuses in the 
# directory structure. This status only occurs when a file has been closed after
# it has been opened for writing. This ensures no file will be processed that is
# incomplete.
if [[ -e $sourcedir ]]; then
  inotifywait -mr -e close_write $sourcedir | while read line; do

# Get the name of whatever new file was just closed.
    parentdir="$(echo "$line" | awk '{print $1}')"
    newfile="$(echo "$line" | awk '{print $3}')"

# Log the successful write of the file
    echo -e "$(date +%d" "%b" "%Y" "%H":"%M":"%S) $newfile has been successfully copied to $parentdir" >> $logfile

# Virus scan the file
    /usr/local/bin/uvscan --SILENT $newfile
    uvscanstatus=$?

# If the file was clean (uvscan exit status 0), move the file to the 
# appropriate destination based on the identifier type (in the filename)
      if [[ $uvscanstatus -eq 0 ]]; then
        echo -e "$(date +%d" "%b" "%Y" "%H":"%M":"%S) $sourcedir/$newfile has been successfully virus scanned and is CLEAN" >> $logfile

# Use the filename to determine what type of file (identifier_type) it is, this will determine what
# funtion to use for setting the final location(s) the data will be moved to.
        newfiletype="$(echo "$newfile" | awk -F'.' '{print $2}')"
        for typecheck in "${identifier_type[@]}"; do
          match_type=0
          if [[ $newfiletype == $typecheck ]]; then
            function_to_run=$(echo "$typecheck" | tr [:upper:] [:lower:])
            run_$function_to_run
            match_type=1
            break
          fi
        done

# The match_type variable will still be set to zero
# if none of the known identifier types matched.
# At this point, call the function for a default location
# to send the files to.
        if [[ $match_type -eq 0 ]]; then
          run_catchall
        fi

# Move the file to the necessary desintation(s). These are specified in the filesorter.conf file.
# Rsync is being used for this operation in case in the future sources modified/created
# to use scp, sftp, etc.
          for endpoint in "${final_location[@]}"; do
            dest_parentdir=$(echo "$parentdir" | sed -e "s.$sourcedir\\/..")
            if [[ $(echo "$parentdir") == $(echo "$sourcedir/") ]]; then
              rsync -a $parentdir$newfile $endpoint
              echo -e "$(date +%d" "%b" "%Y" "%H":"%M":"%S) $sourcedir/$newfile has been successfully moved to $endpoint" >> $logfile
            elif [[ -d $endpoint/$dest_parentdir ]]; then
              rsync -a $parentdir$newfile $endpoint/$dest_parentdir
              echo -e "$(date +%d" "%b" "%Y" "%H":"%M":"%S) $sourcedir/$newfile has been successfully moved to $endpoint/$dest_parentdir" >> $logfile
            else rsync -aR $sourcedir/./$dest_parentdir$newfile $endpoint
              echo -e "$(date +%d" "%b" "%Y" "%H":"%M":"%S) $sourcedir/$newfile has been successfully moved to $endpoint/$dest_parentdir" >> $logfile
            fi
          done

# Cleanup the file that was just copied
          rm -f $parentdir$newfile

### ========    THIS SECTION WILL RECURSIVELY PERFORM CLEANUP      ======== ###
### ========    ON THE SOURCE [WATCHED] DIRECTORY AGGRESSIVELY     ======== ###
### ======== USE ONLY IF YOU WANT TO KEEP THE SOURCEDIR PRISTINE!  ======== ###
#
#
# Cleanup a directory (bottom-up, i.e., subdirs FIRST) if it is empty and has not been written to in 10 seconds (in the background)
#         while true; do
#           for victim in $(find $sourcedir -xdev -type d); do
#           sleep .2
#           isdirempty=$(ls $victim)
#           if [[ $(echo "$victim/") != $(echo "$sourcedir/" ]] && [[ -z $isdirempty ]]; then
#             nowTime=$(date +%s)
#             statTime=$(stat -c %Y $victim)
#             diffTime=$(($nowTime - $statTime))
#             if [[ $diffTime -ge 10 ]]; then
#               rm -rf $victim
#             fi
#           fi
#           done
#         done &
#
### ======================================================================= ###

# Cleanup the array variable so the next iteration can not cause trouble
          unset final_location

# If the file was not clean, log the error and email an alert to the email_recipient specified 
# in the filesorter.conf file
      else echo -e "$(date +%d" "%b" "%Y" "%H":"%M":"%S) $sourcedir/$newfile FAILED A VIRUS SCAN and WILL NOT be processed" >> $logfile
        echo -e "$(date +%d" "%b" "%Y" "%H":"%M":"%S) $sourcedir/$newfile FAILED A VIRUS SCAN and WILL NOT be processed.\nThis error reported by script $0" | mailx -s "VIRUS FOUND ON $HOSTNAME" $email_recipient
      fi
  done
fi
done
