#!/bin/bash

# source the ciop functions (e.g. ciop-log, ciop-getparam)
source ${ciop_job_include}

# set the environment variables to use ESA SNAP toolbox
source $_CIOP_APPLICATION_PATH/gpt/snap_include.sh
# put /opt/anaconda/bin ahead to the PATH list to ensure gdal to point to the anaconda installation dir
export PATH=/opt/anaconda/bin:${PATH}

# define the exit codes
SUCCESS=0
SNAP_REQUEST_ERROR=1
ERR_SNAP=2
ERR_NODATA=3
ERR_NORETRIEVEDPROD=4
ERR_GETMISSION=5
ERR_GETDATA=6
ERR_WRONGINPUTNUM=7
ERR_GETPRODTYPE=8
ERR_WRONGPRODTYPE=9
ERR_GETPRODMTD=10
ERR_PCONVERT=11
ERR_PROPERTIES_FILE_CREATOR=12
ERR_CONVERT=13
ERR_AOI=14
ERR_GET_MISSION_ID=15

# add a trap to exit gracefully
function cleanExit ()
{
    local retval=$?
    local msg=""

    case ${retval} in
        ${SUCCESS})                     msg="Processing successfully concluded";;
        ${SNAP_REQUEST_ERROR})          msg="Could not create snap request file";;
        ${ERR_SNAP})                    msg="SNAP failed to process";;
        ${ERR_NODATA})                  msg="Could not retrieve the input data";;
        ${ERR_NORETRIEVEDPROD})         msg="Product not correctly downloaded";;
        ${ERR_GETMISSION})              msg="Error while retrieving mission name from product name or mission data not supported";;
        ${ERR_GETDATA})                 msg="Error while discovering product";;
        ${ERR_WRONGINPUTNUM})           msg="Number of input products not equal to 3";;
        ${ERR_GETPRODTYPE})             msg="Error while retrieving product type info from input product name";;
        ${ERR_WRONGPRODTYPE})           msg="Product type not supported";;
        ${ERR_GETPRODMTD})              msg="Error while retrieving metadata file from product";;
        ${ERR_PCONVERT})                msg="PCONVERT failed to process";;
        ${ERR_PROPERTIES_FILE_CREATOR}) msg="Could not create the .properties file";;
        ${ERR_CONVERT})        	        msg="Error generating output product";;
        ${ERR_AOI})                     msg="Error: no intersection between input products";;
	${ERR_GET_MISSION_ID})          msg="Error while getting short mission identifier from mission name";;
        *)                              msg="Unknown error";;
    esac

   [ ${retval} -ne 0 ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
   # remove temp data if not debug mode and if not ${ERR_AOI} (this last condition is because if temp data is 
   # removed this error is no longer catched in the 4 task execution attempts)
   if [ $DEBUG -ne 1 ] && [ ${retval} -ne ${ERR_AOI} ]; then
        [ ${retval} -ne 0 ] && hadoop dfs -rmr $(dirname "${inputfiles[0]}")
   fi
   exit ${retval}

}

trap cleanExit EXIT

function create_snap_request_stack(){
# function call: create_snap_request_stack "${inputfilesDIM_list}" "${outProdTIF}" "${numProd}"

    # function which creates the actual request from
    # a template and returns the path to the request

    # get number of inputs
    inputNum=$#
    # check on number of inputs
    if [ "$inputNum" -ne "3" ] ; then
        return ${SNAP_REQUEST_ERROR}
    fi

    local inputfilesDIM_list=$1
    local outProdTIF=$2
    local numProd=$3

    #sets the output filename
    snap_request_filename="${TMPDIR}/$( uuidgen ).xml"

   cat << EOF > ${snap_request_filename}
<graph id="Graph">
  <version>1.0</version>
  <node id="ProductSet-Reader">
    <operator>ProductSet-Reader</operator>
    <sources/>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <fileList>${inputfilesDIM_list}</fileList>
    </parameters>
  </node>
<node id="CreateStack">
    <operator>CreateStack</operator>
    <sources>
      <sourceProduct.$numProd refid="ProductSet-Reader"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <masterBands/>
      <sourceBands/>
      <resamplingType>CUBIC_CONVOLUTION</resamplingType>
      <extent>Minimum</extent>
      <initialOffsetMethod>Product Geolocation</initialOffsetMethod>
    </parameters>
  </node>
  <node id="Write">
    <operator>Write</operator>
    <sources>
      <sourceProduct refid="CreateStack"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outProdTIF}</file>
      <formatName>GeoTIFF-BigTIFF</formatName>
    </parameters>
  </node>
  <applicationData id="Presentation">
    <Description/>
    <node id="Write">
            <displayPosition x="455.0" y="135.0"/>
    </node>
    <node id="CreateStack">
      <displayPosition x="240.0" y="132.0"/>
    </node>
    <node id="ProductSet-Reader">
      <displayPosition x="39.0" y="131.0"/>
    </node>
  </applicationData>
</graph>
EOF

    [ $? -eq 0 ] && {
        echo "${snap_request_filename}"
        return 0
    } || return ${SNAP_REQUEST_ERROR}

}


function propertiesFileCratorTIF(){
# function call propertiesFileCratorTIF "${outputProdTIF}" "${description}" "{prodList_txt}"  "${processingTime}" "${properties_filename}"
    # get number of inputs
    inputNum=$#
    # check on number of inputs
    if [ "$inputNum" -ne "5" ]; then
        return ${ERR_PROPERTIES_FILE_CREATOR}
    fi

    # function which creates the .properties file to attach to the output tif file
    local outputProductTif=$1
    local description=$2
    local prodList_txt=$3
    local processingTime=$4
    local properties_filename=$5

    outputProductTIF_basename=$(basename "${outputProductTif}")
    prodList=$( cat ${prodList_txt} )

    cat << EOF > ${properties_filename}
title = ${outputProductTIF_basename}
Service\ Name = Band combination 
Description = ${description}
processingTime = ${processingTime}
${prodList}
EOF

    [ $? -eq 0 ] && {
        echo "${properties_filename}"
        return 0
    } || return ${ERR_PROPERTIES_FILE_CREATOR}

}

function get_polarization_s1() {

  local productName=$1

  #productName assumed like S1A_IW_SLC__1SPP_* where PP is the polarization to be extracted

  polarizationName=$( echo ${productName:14:2} )
  [ -z "${polarizationName}" ] && return ${ERR_GETPOLARIZATION}

  #check on extracted polarization
  # allowed values are: SH SV DH DV
  if [ "${polarizationName}" = "DH" ] || [ "${polarizationName}" = "DV" ] || [ "${polarizationName}" = "SH" ] || [ "${polarizationName}" = "SV" ]; then
     echo ${polarizationName}
     return 0
  else
     return ${ERR_WRONGPOLARIZATION}
  fi
}



# function that get the complete mission name and returns its short version 
function getMissionShortId()
{
# function call missionShortId=$(getMissionShortId "${mission}")

# get number of inputs
inputNum=$#
# check on number of inputs
if [ "$inputNum" -ne "1" ]; then
    return ${ERR_GET_MISSION_ID}
fi
local mission=$1
case "$mission" in
    "Sentinel-1")
	echo "S1"
        ;;

    "Sentinel-2")
        echo "S2"
        ;;
    "Sentinel-3")
	echo "S3"
	;;
    "UK-DMC2")
        echo "UKDMC2"
        ;;

    "Kompsat-2")
        echo "K2"
        ;;

    "Kompsat-3")
        echo "K3"
        ;;

    "Landsat-8")
        echo "LS8"
        ;;
        
    "Pleiades")
        echo "PHR"
        ;;

    "Radarsat-2")
        echo "RS2"
        ;;

    SPOT-[6-7])
        echo "SPOT"
        ;;

    "Kompsat-5")
	echo "K5"
        ;;

    "VRSS1")
	    echo "VRSS1"
        ;;

    "RapidEye")
        echo "RE"
	    ;;

	"GF2")
	    echo "GF2"
	    ;;

    "Alos-2")
        echo "ALOS2"
        ;;

    "Kanopus-V")
        echo "KNV"
	    ;;

    "Resurs-P")
	    echo "RSP"
	    ;;
        
    "TerraSAR-X")
	    echo "TSX"
		;;

    *)
        echo "NA"
        ;;
esac

return 0
}

function main()
{
    [ $DEBUG -eq 1 ] && echo $SNAP_HOME
    [ $DEBUG -eq 1 ] && echo $SNAP_VERSION
    [ $DEBUG -eq 1 ] && which gdal_translate
    #get input product list and convert it into an array
    local -a inputfiles=($@)

    #get the number of products to be processed
    inputfilesNum=$#
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    ciop-log "DEBUG" "Number of input products ${inputfilesNum}"
    
    # Always 3 input expected: "red.tar" "green.tar" "blue.tar")    
    [ ${inputfilesNum} -eq 3 ] || return $ERR_WRONGINPUTNUM
    #get red band index
    local redBandIndex="`ciop-getparam redBandIndex`"
    # log the value, it helps debugging.
    ciop-log "DEBUG" "Red band identifier provided: ${redBandIndex}"
    #get green band index
    local greenBandIndex="`ciop-getparam greenBandIndex`"
    # log the value, it helps debugging.
    ciop-log "DEBUG" "Green band identifier provided: ${greenBandIndex}"
    #get blue band index
    local blueBandIndex="`ciop-getparam blueBandIndex`"
    # log the value, it helps debugging.
    ciop-log "DEBUG" "Blue band identifier provided: ${blueBandIndex}"
	
    # loop on input products to retrieve them and fill list for stacking operation
    declare -a inputfilesDIM
    declare -a inputfilesProp
    redIndex=""
    greenIndex=""
    blueIndex=""
    masterIndex=""
    prodList_prop=${TMPDIR}/prop.txt
    inputfilesNum_real=$inputfilesNum
    let "inputfilesNum-=1"
    for index in `seq 0 $inputfilesNum`;
    do
        # report activity in log
        ciop-log "INFO" "Retrieving ${inputfiles[$index]} from storage"
        retrieved=$( ciop-copy -U -o $TMPDIR "${inputfiles[$index]}" )
        # check if the file was retrieved, if not exit with the error code $ERR_NODATA
        [ $? -eq 0 ] && [ -e "${retrieved}" ] || return ${ERR_NODATA}
        # report activity in the log
        ciop-log "INFO" "Retrieved ${retrieved}"
        cd $TMPDIR
        tar -xvf `basename ${retrieved}` &> /dev/null
        # let's check the return value
        [ $? -eq 0 ] || return ${ERR_NODATA}
        # remove tar file
        rm ${retrieved}
        # get name of uncompressed product in DIM format
        # NOTE: for each loop step, the TMPDIR is cleansd, so the unique product contained is the current one
        inputDIM=$( ls *.dim)
	cloudTIF=$( ls *.tif)
        # move current dim product to input dir
 	ciop-log "INFO" "Tif retrieved is ${cloudTIF}"
        mv *.d* $INPUTDIR
        mv *.tif $OUTPUTDIR/ 
        # full path of input dim product after move
        inputDIM=${INPUTDIR}/${inputDIM}
        # get name of properties product
        # NOTE: for each loop step, the TMPDIR is cleansd, so the unique product contained is the current one
        inputProp=$( ls *.properties)
        # move to input dir
        mv *.properties $INPUTDIR
        # full path of input properties product after move
        inputProp=${INPUTDIR}/${inputProp}
        cd - &> /dev/null
        inputfilesDIM+=("${inputDIM}") # Array append
        inputfilesProp+=("${inputProp}") # Array append
        #save product index
        [[ "$(basename $inputDIM | grep red)" != "" ]] && redIndex=$index
        [[ "$(basename $inputDIM | grep green)" != "" ]] && greenIndex=$index
	    [[ "$(basename $inputDIM | grep blue)" != "" ]] && blueIndex=$index
        # save master index
        currentIsMaster=$(cat ${inputProp} | grep isMaster | sed -n -e 's|^.*isMaster=\(.*\)|\1|p')
        [[ "${currentIsMaster}" == "1" ]] && masterIndex=$index
    done

    # data list for stacking
    # First band must be the master one to resample the remaining ones wrt the master one that is the first in the satcking operator
    # stack order
    declare -a stackOrderRGB
    firstIndexInstack=""
    secondIndexInStack=""
    thirdIndexInStack=""
    case $masterIndex in
        "$redIndex") #RED MASTER	
	    firstIndexInstack=${redIndex}
            secondIndexInStack=${greenIndex}
            thirdIndexInStack=${blueIndex}
            stackOrderRGB=(1 2 3)
        ;;
        "$greenIndex") #GREEN MASTER
            firstIndexInstack=${greenIndex}
            secondIndexInStack=${blueIndex}
            thirdIndexInStack=${redIndex}
            stackOrderRGB=(3 1 2)
        ;;
        "$blueIndex") #BLUE MASTER
            firstIndexInstack=${blueIndex}
            secondIndexInStack=${redIndex}
            thirdIndexInStack=${greenIndex}
            stackOrderRGB=(2 3 1)
        ;;
    esac
    
    inputfilesDIM_list_csv=${inputfilesDIM["${firstIndexInstack}"]},${inputfilesDIM["${secondIndexInStack}"]},${inputfilesDIM["${thirdIndexInStack}"]}
    # data list for properties extraction 
    declare -a inputfilesProp_list
    inputfilesProp_list+=("${inputfilesProp["${redIndex}"]}")
    inputfilesProp_list+=("${inputfilesProp["${greenIndex}"]}") 
    inputfilesProp_list+=("${inputfilesProp["${blueIndex}"]}")
    # mission identifier list
    declare -a mission_list
    declare -a missionShortId_list
    # band index list
    declare -a bandShortIndex_list	
    # fill product properties
    for index in `seq 0 $inputfilesNum`;
    do
        prodName=$(cat ${inputfilesProp_list[$index]} | grep product | sed -n -e 's|^.*product=\(.*\)|\1|p')
        bandIdentifier=$(cat ${inputfilesProp_list[$index]} | grep band | sed -n -e 's|^.*band=\(.*\)|\1|p')
        missionId=$(cat ${inputfilesProp_list[$index]} | grep mission | sed -n -e 's|^.*mission=\(.*\)|\1|p')
        case $index in
            "0") #RED
	        echo Red_Product=$prodName > $prodList_prop
                echo Red_Product_Band=$bandIdentifier >> $prodList_prop
                echo Red_Product_Mission=$missionId >> $prodList_prop
		bandId=${redBandIndex}
	        ;;
            "1") #GREEN
		echo Green_Product=$prodName >> $prodList_prop
                echo Green_Product_Band=$bandIdentifier >> $prodList_prop
                echo Green_Product_Mission=$missionId >> $prodList_prop
		bandId=${greenBandIndex}
                ;;
	    "2") #BLUE
	        echo Blue_Product=$prodName >> $prodList_prop
                echo Blue_Product_Band=$bandIdentifier >> $prodList_prop
                echo Blue_Product_Mission=$missionId >> $prodList_prop
                pixelSpacingMeters=$(cat ${inputfilesProp[$masterIndex]} | grep pixelSpacingMeters | sed -n -e 's|^.*pixelSpacingMeters=\(.*\)|\1|p')
                echo pixelSpacingMeters=$pixelSpacingMeters >> $prodList_prop
		bandId=${blueBandIndex}
                ;;
        esac
        # report activity in the log
	ciop-log "DEBUG" "Prodname = ${prodName}"
        ciop-log "DEBUG" "Mission ID: ${missionId}"
        mission_list+=("${missionId}")
	missionShortId=$(getMissionShortId "${missionId}")
        # report activity in the log
        ciop-log "DEBUG" "Short mission ID: ${missionShortId}"
	missionShortId_list+=("${missionShortId}")
        bandShortIndex=$(echo "${bandId}" | sed -n -e 's|^.*band_\(.*\)|\1|p')
        # report activity in the log
        ciop-log "DEBUG" "Short band index: ${bandShortIndex}"
	bandShortIndex_list+=("${bandShortIndex}")
    done 
                    
    ## DATA STACKING 
    # report activity in the log
    ciop-log "INFO" "Preparing SNAP request file for products stacking"
    # output prodcut name
    basenameStackNoExt=stack_product
    outProdTIF=${TMPDIR}/${basenameStackNoExt}.tif
    # prepare the SNAP request
    SNAP_REQUEST=$( create_snap_request_stack "${inputfilesDIM_list_csv}" "${outProdTIF}" "${inputfilesNum_real}" )
    [ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
    [ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
    # report activity in the log
    ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
    # report activity in the log
    ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for products stacking"
    # invoke the ESA SNAP toolbox
    gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
    returncode=$?
    test_txt=$(cat log.txt | grep "invalid region")
    rm log.txt
    # catch proper error if any
    if [ $returncode -ne 0 ] ; then
        if [[ "${test_txt}" != "" ]]; then
            # error due to void intersection between input data 
            return ${ERR_AOI}
        else
            # generic snap-gpt execution error
            return ${ERR_SNAP}
        fi
    fi
 
    ## RGB FULL RESOLUTION CREATION
    # report activity in the log
    ciop-log "INFO" "Full resolution RGB TIF visualization product creation"
    
    #temporary tif files list
    declare -a tmpProd_list=("temp-outputfile_band_r.tif" "temp-outputfile_band_g.tif" "temp-outputfile_band_b.tif")
    declare -a outRGB_list=("${OUTPUTDIR}/R_${missionShortId_list[0]}_${bandShortIndex_list[0]}" "${OUTPUTDIR}/G_${missionShortId_list[1]}_${bandShortIndex_list[1]}" "${OUTPUTDIR}/B_${missionShortId_list[2]}_${bandShortIndex_list[2]}")
    declare -a tmpProd_list_pI=("temp-outputfile_band_r_pI.tif" "temp-outputfile_band_g_pI.tif" "temp-outputfile_band_b_pI.tif")
    declare -a tmpProd_list_pII=("temp-outputfile_band_r_pII.tif" "temp-outputfile_band_g_pII.tif" "temp-outputfile_band_b_pII.tif")
    outputRGB=${OUTPUTDIR}/RGB_${missionShortId_list[0]}_${bandShortIndex_list[0]}_${missionShortId_list[1]}_${bandShortIndex_list[1]}_${missionShortId_list[2]}_${bandShortIndex_list[2]}
    # loop on individual bands for radiometric enhancement and output production
    for index in `seq 0 $inputfilesNum`;
    do
        mission="${mission_list[$index]}"
	bandnumber="${bandShortIndex_list[$index]}"
        # tailored enhancement for some SAR missions
	if [ ${mission} = "Radarsat-2" ]; then
               #linear strecth between -15 dB and +5 dB
               python $_CIOP_APPLICATION_PATH/rgb_combination/linear_stretch.py "${outProdTIF}" "${stackOrderRGB[$index]}" -15 5 "${tmpProd_list[$index]}"
        elif [ ${mission} = "Sentinel-1" ]; then
               #Retrieve polarization type
               polType=$( get_polarization_s1 "${prodName}" )
               if [ ${polType} = "DH" ] || [ ${polType} = "DV" ] && [ ${bandnumber} = "2" ]; then
                       python $_CIOP_APPLICATION_PATH/rgb_combination/linear_stretch.py "${outProdTIF}" "${stackOrderRGB[$index]}" -25 5 "${tmpProd_list[$index]}"
                       ciop-log "DEBUG" "Chosen for -25 5 scaling because: Pol: ${polType},Band: ${bandnumber} and Mission: ${mission}"
               else
                       python $_CIOP_APPLICATION_PATH/rgb_combination/linear_stretch.py "${outProdTIF}" "${stackOrderRGB[$index]}" -15 5 "${tmpProd_list[$index]}"
                       ciop-log "DEBUG" "Chosen for -15 5 scaling because: Pol: ${polType},Band: ${bandnumber} and Mission: ${mission}"
               fi
           # generic enhancement for all the other missions
 
        # generic enhancement for all the other missions
        else
            # histogram skip (percentiles from 2 to 96)
            python $_CIOP_APPLICATION_PATH/rgb_combination/hist_skip_no_zero.py "${outProdTIF}" "${stackOrderRGB[$index]}" 2 96 "${tmpProd_list[$index]}"
       #     zMin=$(gdalinfo -mm "${outProdTIF}" | grep Min | sed -ne $((${index}+1))p | tr -d 's/*Computed Min\/Max=//p'| cut -d "," -f 1)
       #     zMax=$(gdalinfo -mm "${outProdTIF}" | grep Min | sed -ne $((${index}+1))p | tr -d 's/*Computed Min\/Max=//p'| cut -d "," -f 2)
       #     python $_CIOP_APPLICATION_PATH/rgb_combination/linear_stretch.py "${outProdTIF}" "${stackOrderRGB[$index]}" $zMin $zMax "${tmpProd_list_pI[$index]}"
            echo $index $zMin $zMax > "${OUTPUTDIR}"/toto
            ciop-publish -m "${OUTPUTDIR}"/*
            if [ ${mission} = "Sentinel-2"  ]; then
                python $_CIOP_APPLICATION_PATH/rgb_combination/linear_stretch.py "${outProdTIF}" "${stackOrderRGB[$index]}" 0 0.3 "${tmpProd_list_pII[$index]}"
		zMin=$(gdalinfo -mm "${outProdTIF}" | grep Min | sed -ne $((${index}+1))p | tr -d 's/*Computed Min\/Max=//p'| cut -d "," -f 1)
	        zMax=$(gdalinfo -mm "${outProdTIF}" | grep Min | sed -ne $((${index}+1))p | tr -d 's/*Computed Min\/Max=//p'| cut -d "," -f 2)
	        python $_CIOP_APPLICATION_PATH/rgb_combination/linear_stretch.py "${outProdTIF}" "${stackOrderRGB[$index]}" $zMin $zMax "${tmpProd_list_pI[$index]}"
	        echo $index $zMin $zMax > "${OUTPUTDIR}"/toto
            fi    
        fi
        #re-projection
        gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" -co "BIGTIFF=YES" "${tmpProd_list[$index]}" "${outRGB_list[$index]}".tif
       # gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" -co "BIGTIFF=YES" "${tmpProd_list_pI[$index]}" "${outRGB_list[$index]}"_pI.tif  
        returnCode=$?
        [ $returnCode -eq 0 ] || return ${ERR_CONVERT}
        if [ ${mission} = "Sentinel-2"  ]; then
		gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" -co "BIGTIFF=YES" "${tmpProd_list_pI[$index]}" "${outRGB_list[$index]}"_pI.tif
	 	gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" -co "BIGTIFF=YES" "${tmpProd_list_pI[$index]}" "${outRGB_list[$index]}"_pII.tif  
        fi

        #Add overviews
        gdaladdo -r average "${outRGB_list[$index]}".tif 2 4 8 16
        returnCode=$?
        [ $returnCode -eq 0 ] || return ${ERR_CONVERT}    
#        gdaladdo -r average "${outRGB_list[$index]}"_pI.tif 2 4 8 16
        returnCode=$?
        [ $returnCode -eq 0 ] || return ${ERR_CONVERT}
        if [ ${mission} = "Sentinel-2"  ]; then
        	gdaladdo -r average "${outRGB_list[$index]}"_pII.tif 2 4 8 16
		gdaladdo -r average "${outRGB_list[$index]}"_pI.tif 2 4 8 16
        fi

        # Create PNG output
        gdal_translate -ot Byte -of PNG "${outRGB_list[$index]}".tif "${outRGB_list[$index]}".png

        #remove temp xml file produced together with png
        rm -f "${outRGB_list[$index]}".png.aux.xml
        # create properties file for phase tif product
        processingTime=$( date )
        description="Individual band product"
        output_properties=$( propertiesFileCratorTIF  "${outRGB_list[$index]}".tif "${description}" "${inputfilesProp_list[$index]}" "${processingTime}" "${outRGB_list[$index]}".properties )         
    done
    # merge radiometric enhanced bands
    gdal_merge.py -separate -n 0 -a_nodata 0 -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" "temp-outputfile_band_r.tif" "temp-outputfile_band_g.tif" "temp-outputfile_band_b.tif" -o temp-outputfile.tif
#    gdal_merge.py -separate -n 0 -a_nodata 0 -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" "temp-outputfile_band_r_pI.tif" "temp-outputfile_band_g_pI.tif" "temp-outputfile_band_b_pI.tif" -o temp-outputfile_pI.tif
    if [ ${mission} = "Sentinel-2"  ]; then
        gdal_merge.py -separate -n 0 -a_nodata 0 -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" "temp-outputfile_band_r_pII.tif" "temp-outputfile_band_g_pII.tif" "temp-outputfile_band_b_pII.tif" -o temp-outputfile_pII.tif
	gdal_merge.py -separate -n 0 -a_nodata 0 -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" "temp-outputfile_band_r_pI.tif" "temp-outputfile_band_g_pI.tif" "temp-outputfile_band_b_pI.tif" -o temp-outputfile_pI.tif
    fi
    
    #remove temp files
    rm temp-outputfile_band_r.tif temp-outputfile_band_g.tif temp-outputfile_band_b.tif
    rm temp-outputfile_band_r_pI.tif temp-outputfile_band_g_pI.tif temp-outputfile_band_b_pI.tif
    if [ ${mission} = "Sentinel-2"  ]; then
        rm temp-outputfile_band_r_pII.tif temp-outputfile_band_g_pII.tif temp-outputfile_band_b_pII.tif    
    fi    

    #re-projection
    gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" -co "BIGTIFF=YES" temp-outputfile.tif ${outputRGB}.tif
    returnCode=$?
    [ $returnCode -eq 0 ] || return ${ERR_CONVERT}
 #   gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" -co "BIGTIFF=YES" temp-outputfile_pI.tif ${outputRGB}_pI.tif
    returnCode=$?
    [ $returnCode -eq 0 ] || return ${ERR_CONVERT}
    if [ ${mission} = "Sentinel-2"  ]; then
    		gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" -co "BIGTIFF=YES" temp-outputfile_pII.tif ${outputRGB}_pII.tif
 		gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" -co "BIGTIFF=YES" temp-outputfile_pI.tif ${outputRGB}_pI.tif
    fi 

    #Remove temporary file
    rm -f temp-outputfile.tif
    rm -f temp-outputfile_pI.tif
    if [ ${mission} = "Sentinel-2"  ]; then
        rm -f temp-outputfile_pII.tif
    fi

    #Add overviews
    gdaladdo -r average ${outputRGB}.tif 2 4 8 16
    returnCode=$?
    [ $returnCode -eq 0 ] || return ${ERR_CONVERT} 
#    gdaladdo -r average ${outputRGB}_pI.tif 2 4 8 16
    returnCode=$?
    [ $returnCode -eq 0 ] || return ${ERR_CONVERT}   
    if [ ${mission} = "Sentinel-2"  ]; then
        gdaladdo -r average ${outputRGB}_pII.tif 2 4 8 16
	gdaladdo -r average ${outputRGB}_pI.tif 2 4 8 16
    fi
    # Create PNG output
    gdal_translate -ot Byte -of PNG ${outputRGB}.tif ${outputRGB}.png
#    gdal_translate -ot Byte -of PNG ${outputRGB}_pI.tif ${outputRGB}_pI.png
    if [ ${mission} = "Sentinel-2"  ]; then
        gdal_translate -ot Byte -of PNG ${outputRGB}_pII.tif ${outputRGB}_pII.png
	gdal_translate -ot Byte -of PNG ${outputRGB}_pI.tif ${outputRGB}_pI.png
        rm -f ${outputRGB}_pII.png.aux.xml
    fi
    #remove temp xml file produced together with png
    rm -f ${outputRGB}.png.aux.xml
    rm -f ${outputRGB}_pI.png.aux.xml
    # create properties file for phase tif product
    processingTime=$( date )
    description="RGB combination - 2-96 percent of histogram"
    output_properties=$( propertiesFileCratorTIF  "${outputRGB}".tif "${description}" "${prodList_prop}" "${processingTime}" "${outputRGB}".properties )
    description_pI="RGB combination - Min to Max"
    output_properties=$( propertiesFileCratorTIF  "${outputRGB}"_pI.tif "${description_pI}" "${prodList_prop}_pI" "${processingTime}" "${outputRGB}"_pI.properties )
    if [ ${mission} = "Sentinel-2"  ]; then
        description_pI="RGB combination - Min to Max"
	output_properties=$( propertiesFileCratorTIF  "${outputRGB}"_pI.tif "${description_pI}" "${prodList_prop}_pI" "${processingTime}" "${outputRGB}"_pI.properties )

	description_pII="RGB combination - Min to Max"
        
	output_properties=$( propertiesFileCratorTIF  "${outputRGB}"_pII.tif "${description_pII}" "${prodList_prop}_pII" "${processingTime}" "${outputRGB}"_pII.properties )
    fi

    # report activity in the log
    ciop-log "DEBUG" "Properties file created: ${output_properties}"
    # publish the coergistered product
    ciop-log "INFO" "Publishing Output Products"
    ciop-publish -m "${OUTPUTDIR}"/*

    # cleanup
    rm -rf "${INPUTDIR}"/* "${TMPDIR}"/* "${OUTPUTDIR}"/*
    if [ $DEBUG -ne 1 ] ; then
        for index in `seq 0 $inputfilesNum`;
        do
                hadoop dfs -rmr "${inputfiles[$index]}"
        done
    fi

    return ${SUCCESS}
}

# create the output folder to store the output products and export it
mkdir -p ${TMPDIR}/output
export OUTPUTDIR=${TMPDIR}/output
mkdir -p ${TMPDIR}/input
export INPUTDIR=${TMPDIR}/input
# debug flag setting
export DEBUG=0

# loop on input file to create a product array that will be processed by the main process
declare -a inputfiles
while read inputfile; do
    inputfiles+=("${inputfile}") # Array append
done
# run main process
main ${inputfiles[@]}
res=$?
[ ${res} -ne 0 ] && exit ${res}

exit $SUCCESS

