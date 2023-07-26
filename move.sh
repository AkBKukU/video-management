#!/bin/bash

# Primary video archival method for all videos on the Tech Tangent channel.
# Requires braw-decode available on github.
# 
# Goes through all projects in folder and converts and archives those with
# exported davinci resolve project file as an indication of project completion

# Notes:
# verify and verifyFin both exist to have one that checks for braw files and one that doesn't

workDir="/opt/videos/projects/"
cd "$workDir"

# Check if script is currently running
# TODO - Does this nerf retry? Do I still need retry?
if [[ -e "zz-working" ]]
then
    echo "move running already..."
    exit 0
    
else
    touch zz-working
fi

# Origin of projects
driveSrc="production"
# Temp folder for holding projects being converted
driveConv="archive-02-convert"
# Final folder for converted and archived projects
driveFin="archive-03-finished"
# Final archive folder
driveDest="/opt/videos/storage/ice/2023/"

# Get script path to re-run on retry
ScriptLoc="$(readlink -f "$0")"

# Location of braw files in project directory
# These will be excluded from final copy
vidDir="assets/video/braw/"

logs="90-MoveLogs"
logFile="$(date --iso-8601)_move.txt"

retry="$1"

# Copy entire directory structure and all files except for braw video clips
copy()
{
	dir="$1"
	
	echo "$dir: Copying"
	
	# Check for existing folder
	if [[ -d "$driveDest/$dir" ]] ; then
		echo "$dir: [WARN] Folder already exists in destination"  | tee -a $logs/$logFile
	fi
	
	# Create new folder path
	mkdir -p "$driveDest"
	
	# Copy everything but video files
	rsync -LaPv --exclude="$vidDir" "$driveSrc/$dir" "$driveDest"
	

	# Error check
	copyStat=$?
	if [[ $copyStat == 0 ]] ; then
		echo "$dir: [PASS] Copied"  | tee -a $logs/$logFile
	else
		echo "$dir: [FAIL] Copy Failed" | tee -a $logs/$logFile
		exit $copyStat
	fi
	
	# Create empty braw path to re-encode files into
	mkdir -p "$driveDest/$dir/$vidDir"
}


# Verify that all files were copied excluding the braw video folder
verify()
{
	dir="$1"
	echo "$dir: Verifying Contents"
	
	# Paths for current project
	vidSrc="$driveSrc/$dir"
	vidDest="$driveDest/$dir"

	# Created sorted lists of all files in project directory to compare, excluding braw
	original="$(find "$vidSrc" -path "$(basename "$vidDir")" -prune -follow -print | sort | sed "s|$vidSrc||g" | sed "s/\.braw/\.mov/g")"
	copy="$(find "$vidDest" -path "$(basename "$vidDir")" -prune -follow -print | sort | sed "s|$vidDest||g")"

	# Check source and copy directories match, excluding braw
	diff <(echo "$original") <(echo "$copy")
	
	# Error check
	result=$?
	if [[ $result == 0 ]] ; then
		echo "$dir: [PASS] Successfully Verified" | tee -a $logs/$logFile
	else
		echo "$dir: [FAIL] Verification Failed!" | tee -a $logs/$logFile
		
		# Log difference between files
		echo "$dir: [FAIL] diff:" | tee -a $logs/$logFile
        diff <(echo "$original") <(echo "$copy") >> $logs/$logFile
		
		exit $result
	fi
}


# Move project to convert folder to prevent modifications
moveConv()
{
	dir="$1"
	echo "$dir: Moving to Convert"
	
	# Paths for current project
	vidSrc="$driveSrc/$dir"
	vidDest="$driveConv/$dir"
	
    #  Move the project
	mv "$vidSrc" "$vidDest"
	
	# Error check
	result=$?
	if [[ $result == 0 ]] ; then
		echo "$dir: [PASS] Moved to Convert" | tee -a $logs/$logFile
	else
		echo "$dir: [FAIL] Move to Convert Failed!" | tee -a $logs/$logFile
		
		exit $result
	fi

}


# Convert BRAW files into lower bitrate for long term storage
convert()
{
	local rdir="$1"
	echo "In conv: $(pwd)"
	echo "$rdir: Begining Conversion"
	
	# Paths for current project
	local vidSrc="$rdir"
	local vidDest="$driveDest/$rdir"
	
	# Init error check value
	finalresult=0
	
    
    # Check for braw files
    #ls $vidSrc/$vidDir/*.braw
    #result=$?
    #if [[  $result != 0  ]]; then
    #    echo "$dir: [WARN] No Braw Files!" | tee -a $logs/$logFile
    #    return
    #fi
    
    # Go over all braw files
    local clips=( "$vidSrc/"* )
    for clip in "${clips[@]}" ; do
    
		# Check for dir to re-run
		if [ -d "$clip" ]
		then
			echo "$clip is folder, searching deeper..."
			echo ""
			mkdir -p "$driveDest/$clip"
			convert "$clip"
			continue
		else
			echo "$clip: Not dir"
		fi

		if [[ "$clip" != *.braw ]]
		then
			echo "$clip is not braw"
			continue
		fi

        # Get filename only
        output="$(basename "$clip")"
        
        # Check if converted already (only done because ffmpeg is slow)
        if [[ ! -f "$vidDest/${output%.*}.mov" ]]; then

			timecode="$(ffprobe "$clip" 2>&1 | grep timecode | awk '{print $3}'| sed '1q;d')"

			if [[ "$timecode" == "" ]]
			then
				timecode="00:00:00:00"
			fi
			echo "start conv: $(pwd)"

            # Convert braw file
            braw-decode -v -t 4 -c 16pl "$clip" | ffmpeg -i "$clip" -thread_queue_size 20 $(braw-decode -c 16pl -f "$clip") \
                -map 1:v:0 -map 0:a:0 -c:a copy \
				-timecode "$timecode" -metadata timecode="$timecode" \
                -c:v hevc_nvenc -b:v 32M -profile:v rext "$vidDest/${output%.*}.mov"
            result=$?
        else
            echo "[${output%.*}.mov] already exists, skipping" 
            result=0
        fi
        
        # Error check for conversion of file
        if [[ $result != 0 ]] ; then
            # Set error state and remove bad file
            finalresult=1
            rm "$vidDest/$vidDir/${output%.*}.mov"
        fi
    done
    
    # Error check for all files
	if [[ $finalresult == 0 ]] ; then
		echo "$dir: [PASS] Successfully Converted" | tee -a $logs/$logFile
	else
	echo "$dir: [FAIL] Conversion Failed!" | tee -a $logs/$logFile
	exit $result

	fi
}

moveFin()
{
	dir="$1"
	echo "$dir: Moving to Finished"
	vidSrc="$driveConv/$dir"
	vidDest="$driveFin/$dir"
	

	mv "$vidSrc" "$vidDest"
	result=$?
	if [[ $result == 0 ]] ; then
		echo "$dir: [PASS] Moved to Finish" | tee -a $logs/$logFile
	else
		echo "$dir: [FAIL] Move to Finish Failed!" | tee -a $logs/$logFile
		
		exit $result
	fi

}


verifyFin()
{
	dir="$1"
	echo "$dir: Verifying Finished Contents"
	vidSrc="$driveFin/$dir"
	vidDest="$driveDest/$dir"
	
	original="$(find "$vidSrc" -follow -print | sort | sed "s|$vidSrc||g" | sed "s/\.braw/\.mov/g")"
	copy="$(find  "$vidDest" -follow -print | sort | sed "s|$vidDest||g")"

	diff <(echo "$original") <(echo "$copy")
	result=$?
	if [[ $result == 0 ]] ; then
		echo "$dir: [PASS] Successfully Verified Finished" | tee -a $logs/$logFile
	else
		echo "$dir: [FAIL] Finished Verification Failed!" | tee -a $logs/$logFile
		echo "$dir: [FAIL] diff:" | tee -a $logs/$logFile
        diff <(echo "$original") <(echo "$copy") >> $logs/$logFile
		
		if [[ "$retry" != "" ]] ; then
            echo "$dir: [FAIL] Moving Back to Ready and Restarting" | tee -a $logs/$logFile
            vidSrc="$driveFin/$dir"
            vidDest="$driveSrc/$dir"
            
            mv "$vidSrc" "$vidDest"
            exec "$ScriptLoc" "retry"
        fi
	fi
}




## --- Pass 1 - Copy and Prep--- ##

# Log Header
echo " -- Beginning Backup Move -- " | tee -a $logs/$logFile
echo " -- Started: $(date --iso-8601=seconds)Z -- " | tee -a $logs/$logFile

# Go over all project folders
folders=( $driveSrc/* )
for dir in "${folders[@]}" ; do
	
	# Check for active projects
	if [[ $folders == "$driveSrc/*" ]] ; then
		# Empty folder
		echo "Nothing in $driveSrc"
	else

        # Get project name
        dir="$(basename "$dir")" # TODO - Do not overwrite variable
        
        # Check for exported Resolve project file to determine if complete
        echo "Checking: $dir" | tee -a $logs/$logFile
        if [[ "`echo "$driveSrc/$dir/"*.drp`" == "$driveSrc/$dir/*.drp" ]] ; then
            # Project was not complete, move on to next
            echo "$dir not exported"  | tee -a $logs/$logFile
            continue
        fi
        # Project is complete, begin archiving
        
        echo "Archiving Project: " "`echo "$driveSrc/$dir/"*.drp`"  | tee -a $logs/$logFile
        
        # Go through initial archive procedures
        copy "$dir"
        verify "$dir"
        moveConv "$dir"  # TODO - just move it in this line
        # Project is copied and moved, braw to be re-encoded next
	fi
done





## --- Pass 2 - Re-encoding --- ##


# Go over all project folders ready for conversion
folders=( $driveConv/* )
for dir in "${folders[@]}" ; do

    # Check for nothing to convert
	if [[ $folders == "$driveConv/*" ]] ; then
        # Empty folder
        echo "Nothing in $driveConv"
        break
    fi
        

    # Get project name only
    dir="$(basename "$dir")"  # TODO - Do not overwrite variable

    
    # Convert project
    echo "$dir: Converting Contents"
	cd "$driveConv"
    convert "$dir/$vidDir"
	cd "$workDir"
	
	## -- Verification -- ##
	# TODO - just use verifyFin and add a return value to continue with
	# Possibly just remove? verifyFin is called immidiately after this
	echo "$dir: Verifying Contents For Conversion"
	vidSrc="$driveConv/$dir"
	vidDest="$driveDest/$dir"

	original="$(find "$vidSrc" -follow -print | sort | sed "s|$vidSrc||g" | sed "s/\.braw/\.mov/g")"
	copy="$(find  "$vidDest" -follow -print | sort | sed "s|$vidDest||g")"
	
	diff <(echo "$original") <(echo "$copy")
	result=$?
	if [[ $result == 0 ]] ; then
		echo "$dir: [PASS] Successfully Verified Convert" | tee -a $logs/$logFile
	else
		echo "$dir: [FAIL] Convert Verification Failed!" | tee -a $logs/$logFile
		echo "$dir: [FAIL] diff:" | tee -a $logs/$logFile
        diff <(echo "$original") <(echo "$copy") >> $logs/$logFile
        		
		if [[ "$retry" != "" ]] ; then
            echo "$dir: [FAIL] Moving Back to Ready and Restarting" | tee -a $logs/$logFile
            vidSrc="$driveConv/$dir"
            vidDest="$driveSrc/$dir"
            
            mv "$vidSrc" "$vidDest"
            exec "$ScriptLoc" "retry"
        fi
		
		continue $result
	fi
	
	## -- Verification -- ##
	
	
	# Move project to finished holding folder
    moveFin "$dir" # TODO - just move it in this line
done

# One final verification
folders=( "$driveFin"/* )
for dir in "${folders[@]}" ; do

    # Check for nothing to verify
	if [[ $folders == "$driveFin"/* ]] ; then
        # Empty folder
        echo "Nothing in $driveFin"
        break
    fi
    dir="$(basename "$dir")"
    verifyFin "$dir"

done


cd "$workDir"
rm zz-working


