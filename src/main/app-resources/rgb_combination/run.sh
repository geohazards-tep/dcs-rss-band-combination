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
        ${ERR_CONVERT})           	msg="Error generating output product";;
        ${ERR_AOI})                     msg="Error: no intersection between input products";;
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


function main ()
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
    # loop on input products to retrieve them and fill list for stacking operation
    [ ${inputfilesNum} -eq 3 ] || return $ERR_WRONGINPUTNUM
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
        # move current dim product to input dir
        mv *.d* $INPUTDIR
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
    # fill product properties
    for index in `seq 0 $inputfilesNum`;
    do
        prodName=$(cat ${inputfilesProp_list[$index]} | grep product | sed -n -e 's|^.*product=\(.*\)|\1|p')
        bandIdentifier=$(cat ${inputfilesProp_list[$index]} | grep band | sed -n -e 's|^.*band=\(.*\)|\1|p')
        case $index in
            "0") #RED
	        echo Red_Product=$prodName > $prodList_prop
                echo Red_Product_Band=$bandIdentifier >> $prodList_prop
	    ;;
            "1") #GREEN
		echo Green_Product=$prodName >> $prodList_prop
                echo Green_Product_Band=$bandIdentifier >> $prodList_prop
            ;;
	    "2") #BLUE
		echo Blue_Product=$prodName >> $prodList_prop
                echo Blue_Product_Band=$bandIdentifier >> $prodList_prop
	    	pixelSpacingMeters=$(cat ${inputfilesProp[$masterIndex]} | grep pixelSpacingMeters | sed -n -e 's|^.*pixelSpacingMeters=\(.*\)|\1|p')
                echo pixelSpacingMeters=$pixelSpacingMeters >> $prodList_prop
            ;;
	esac
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
    outputRGB_TIF=${OUTPUTDIR}/RGB.tif
    outputRGB_PNG=${OUTPUTDIR}/RGB.png
    outputRGB_Prop=${OUTPUTDIR}/RGB.properties
    
    # create full resolution tif image with Red=B1 Green=B2 Blue=B3 due to given order within stacking operation
    gdal_translate -ot Byte -of GTiff -b ${stackOrderRGB[0]} -b ${stackOrderRGB[1]} -b ${stackOrderRGB[2]} -scale -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" ${outProdTIF} temp-outputfile.tif 
    returnCode=$?
    [ $returnCode -eq 0 ] || return ${ERR_CONVERT}
    rm ${outProdTIF}
    #re-projection
    gdalwarp -ot Byte -t_srs EPSG:4326 -srcnodata 0 -dstnodata 0 -dstalpha -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -co "PHOTOMETRIC=RGB" -co "ALPHA=YES" temp-outputfile.tif ${outputRGB_TIF}
    returnCode=$?
    [ $returnCode -eq 0 ] || return ${ERR_CONVERT}
    #Remove temporary file
    rm -f temp-outputfile.tif
    #Add overviews
    gdaladdo -r average ${outputRGB_TIF} 2 4 8 16
    returnCode=$?
    [ $returnCode -eq 0 ] || return ${ERR_CONVERT}    
    # Create PNG output
    gdal_translate -ot Byte -of PNG ${outputRGB_TIF} ${outputRGB_PNG}
    #remove temp xml file produced together with png
    rm -f ${outputRGB_PNG}.aux.xml
    # create properties file for phase tif product
    processingTime=$( date )
    description="RGB combination"
    output_properties=$( propertiesFileCratorTIF  "${outputRGB_TIF}" "${description}" "${prodList_prop}"  "${processingTime}" "${outputRGB_Prop}" )
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
