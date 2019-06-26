#!/bin/bash

# source the ciop functions (e.g. ciop-log, ciop-getparam)
source ${ciop_job_include}

# set the environment variables to use ESA SNAP toolbox
source $_CIOP_APPLICATION_PATH/gpt/snap_include.sh
# set the environment variables to use ORFEO toolbox
source $_CIOP_APPLICATION_PATH/otb/otb_include.sh
## put /opt/anaconda/bin ahead to the PATH list to ensure gdal to point to the anaconda installation dir
export PATH=/opt/anaconda/bin:${PATH}

# define the exit codes
SUCCESS=0
SNAP_REQUEST_ERROR=1
ERR_SNAP=2
ERR_NOPROD=3
ERR_NORETRIEVEDPROD=4
ERR_GETMISSION=5
ERR_GETDATA=6
ERR_WRONGINPUTNUM=7
ERR_GETPRODTYPE=8
ERR_WRONGPRODTYPE=9
ERR_GETPRODMTD=10
ERR_PCONVERT=11
ERR_GETPIXELSPACING=12
ERR_CALLPREPROCESS=13
ERR_PREPROCESS=14
ERR_UNPACKING=15
ERR_TARGET_RES_PROD=16
ERR_BAND_LIST=17
ERR_WRONGPOLARIZATION=18
ERR_BAND_ID_GET=19
ERR_BAND_SELECT=20
ERR_BAND_ID=21
ERR_AOI=22
ERR_GDAL=23
ERR_GET_BANDS_NUM=24
ERR_GET_PIX_SPACING_TIF=25

# add a trap to exit gracefully
function cleanExit ()
{
    local retval=$?
    local msg=""

    case ${retval} in
        ${SUCCESS})                     msg="Processing successfully concluded";;
        ${SNAP_REQUEST_ERROR})          msg="Could not create snap request file";;
        ${ERR_SNAP})                    msg="SNAP failed to process";;
        ${ERR_NOPROD})                  msg="No product reference input provided";;
        ${ERR_NORETRIEVEDPROD})         msg="Product not correctly downloaded";;
        ${ERR_GETMISSION})              msg="Error while retrieving mission name from product name or mission data not supported";;
        ${ERR_GETDATA})                 msg="Error while discovering product";;
        ${ERR_WRONGINPUTNUM})           msg="Number of input RED product not equal to 1";;
        ${ERR_GETPRODTYPE})             msg="Error while retrieving product type info from input product name";;
        ${ERR_WRONGPRODTYPE})           msg="Product type not supported";;
        ${ERR_GETPRODMTD})              msg="Error while retrieving metadata file from product";;
        ${ERR_PCONVERT})                msg="PCONVERT failed to process";;
        ${ERR_GETPIXELSPACING})         msg="Error while retrieving pixel spacing";;
        ${ERR_CALLPREPROCESS})          msg="Error while calling pre processing function";;
        ${ERR_PREPROCESS})              msg="Error during pre processing execution";;
        ${ERR_UNPACKING})               msg="Error unpacking input product";;
        ${ERR_TARGET_RES_PROD})         msg="Target resolution product is not equal to one of selected input R,G,B product";;
        ${ERR_BAND_LIST})   	        msg="Error while retrieving the list of contained bands within product";;
	${ERR_WRONGPOLARIZATION})       msg="Wrong polarisation retrieved from input product name";;
        ${ERR_BAND_ID_GET})	        msg="Error while retrieving band identifier from product";;
	${ERR_BAND_SELECT})             msg="Error while extracting band from pre-processed product";;
        ${ERR_BAND_ID})       	        msg="Band index not valid for input product (it exceeds the number of contained bands)";;
        ${ERR_AOI})                     msg="Error: input SubsetBoundingBox has no intersection with input data";;
        ${ERR_GDAL})                    msg="Error while executing a GDAL bin";;
        ${ERR_GET_BANDS_NUM})           msg="Error while getting number of bands of TIF product";;
        ${ERR_GET_PIX_SPACING_TIF})     msg="Error while getting pixel spacing from TIF product";;
        *)                              msg="Unknown error";;
    esac

   [ ${retval} -ne 0 ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
   exit ${retval}
}

trap cleanExit EXIT


# function that checks the product type from the product name
function check_product_type() {

  local retrievedProduct=$1
  local mission=$2
  local productName=$( basename "$retrievedProduct")

  if [ ${mission} = "Sentinel-1"  ] ; then
      #productName assumed like S1A_IW_TTTT_* where TTTT is the product type to be extracted
      prodTypeName=$( echo ${productName:7:4} )
      [ -z "${prodTypeName}" ] && return ${ERR_GETPRODTYPE}
      if [ $prodTypeName != "GRDH" ] && [ $prodTypeName != "GRDM" ]; then
          return $ERR_WRONGPRODTYPE
      fi
  fi

  if [ ${mission} = "Sentinel-2"  ] ; then
      ciop-log "INFO" "retrieved product is ${retrievedProduct}"
      full_name=$( (find $retrievedProduct -type d -name "S2*.SAFE") )
      check_name=$( basename "$full_name" )
      ciop-log "INFO" "Fullname is $check_name"
      prodTypeName=${check_name:4:6}
      ciop-log "INFO" "Product type is ${prodTypeName}"
      [ -z "${prodTypeName}" ] && return ${ERR_GETPRODTYPE}
      # log the value, it helps debugging.
      # the log entry is available in the process stderr
      ciop-log "DEBUG" "Retrieved product type: ${prodTypeName}"
      [ $prodTypeName != "MSIL1C" ] && return $ERR_WRONGPRODTYPE
      
  fi
  
  if [ ${mission} = "Sentinel-3" ] ; then
      ciop-log "INFO" "retrieved product is ${productName}"

      prodTypeName=$( echo ${productName:9:3} )
      ciop-log "INFO" "retrieved product is type: ${prodTypeName}"
      if [ $prodTypeName != "EFR" ] && [ $prodTypeName != "ERR" ]; then
          return $ERR_WRONGPRODTYPE
      fi

  fi

  if [[ "${mission}" == "UK-DMC2" ]]; then
      if [[ -d "${retrievedProduct}" ]]; then
          prodTypeName=$(ls ${retrievedProduct} | sed -n -e 's|^.*_\(.*\)\.tif$|\1|p')
	  [[ -z "$prodTypeName" ]] && ciop-log "ERROR" "Failed to get product type from : ${retrievedProduct}"
      else
          ciop-log "ERROR" "Rerieved product ${retrievedProduct} is not a directory"
	  return ${ERR_UNPACKING}
      fi
      [[ "$prodTypeName" != "L1T" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [ ${mission} = "Kompsat-3"  ]; then
      #naming convention K3_”Time”_”OrbNo”_"PassNo"_”ProcLevel”
      prodTypeName=${productName:(-3)}
      if [[ "$prodTypeName" != "L1G" ]] ; then
          return $ERR_WRONGPRODTYPE
      fi  
  fi

  if [ ${mission} = "Landsat-8" ]; then
      #Extract metadata file from Landsat
      filename="${retrievedProduct##*/}"; ext="${filename#*.}"
      ciop-log "INFO" "Retrieving product type from Landsat 8 product: $filename"
      ciop-log "INFO" "Product extension : $ext"
      if [[ "$ext" == "tar.bz" ]]; then
	  ciop-log "INFO" "Running command: tar xjf $retrievedProduct ${filename%%.*}_MTL.txt"
          tar xjf $retrievedProduct ${filename%%.*}_MTL.txt
          returnCode=$?
          [ $returnCode -eq 0 ] || return ${ERR_GETPRODTYPE}
          [[ -e "${filename%%.*}_MTL.txt" ]] || return ${ERR_GETPRODTYPE}
          prodTypeName=$(sed -n -e 's|^.*DATA_TYPE.*\"\(.*\)\".*$|\1|p' ${filename%%.*}_MTL.txt)
          rm -f ${filename%%.*}_MTL.txt
      elif
	  [[ "$ext" == "tar" ]]; then
          ciop-log "INFO" "Running command: tar xf $retrievedProduct *_MTL.txt"
          tar xf $retrievedProduct *_MTL.txt
          returnCode=$?
          [ $returnCode -eq 0 ] || return ${ERR_GETPRODTYPE}
          prodTypeName=$(sed -n -e 's|^.*DATA_TYPE.*\"\(.*\)\".*$|\1|p' *_MTL.txt)
          rm -f *_MTL.txt
      else
          metadatafile=$(ls ${retrievedProduct}/vendor_metadata/*_MTL.txt)
          [[ -e "${metadatafile}" ]] || return ${ERR_GETPRODTYPE}
          prodTypeName=$(sed -n -e 's|^.*DATA_TYPE.*\"\(.*\)\".*$|\1|p' ${metadatafile})
      fi
      # log the value, it helps debugging.
      # the log entry is available in the process stderr
      ciop-log "DEBUG" "Retrieved product type: ${prodTypeName}"
      if [[ "$prodTypeName" != "L1TP" ]] && [[ "$prodTypeName" != "L1T" ]] && [[ "$prodTypeName" != "L1GT" ]] ; then
          return $ERR_WRONGPRODTYPE
      fi
  fi

  if [ ${mission} = "Pleiades" ]; then
      # Get multispectral metadata file
      metadatafile=$(find ${retrievedProduct}/ -name 'DIM_*MS_*.XML')
      [[ -e "${metadatafile}" ]] || return ${ERR_GETPRODTYPE}
      prodTypeName=$(sed -n -e 's|^.*<PROCESSING_LEVEL>\(.*\)</PROCESSING_LEVEL>$|\1|p' ${metadatafile})
      [[ "$prodTypeName" != "ORTHO" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [ ${mission} = "Kompsat-2" ]; then
      if [[ -d "${retrievedProduct}" ]]; then
          prodTypeName=$(find ${retrievedProduct} -name '*.tif' | head -1 | sed -n -e 's|^.*_\(.*\).tif$|\1|p')
          [[ -z "$prodTypeName" ]] && ciop-log "ERROR" "Error prodTypeName is empty"
      else
          ciop-log "ERROR" "KOMPSAT-2 product was not unzipped"
          return ${ERR_UNPACKING}
      fi
      # Only L1G are supported
      [[ "$prodTypeName" != "1G" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "Radarsat-2" ]]; then
      #naming convention <RS2_BeamMode_Date_Time_Polarizations_ProcessingLevel>
      prodTypeName=${productName:(-3)}
      [[ "$prodTypeName" != "SGF" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "SPOT-6" ]] || [[ "${mission}" == "SPOT-7"  ]]; then
        spot_xml=$(find ${retrievedProduct}/ -name 'DIM_SPOT?_*MS_*.XML')
        prodTypeName=$(sed -n -e 's|^.*<DATASET_TYPE>\(.*\)</DATASET_TYPE>$|\1|p' ${spot_xml})
        [[ "$prodTypeName" != "RASTER_ORTHO" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "Kompsat-5" ]]; then
        #naming convention <K5>_<YYYYMMDDhhmmss>_<tttttt>_<nnnnn>_<o>_<MM><SS>_<PP>_<LLL> where LLL is the processing level
        prodTypeName=${productName:47:3}
        [[ "$prodTypeName" != "L1D" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "VRSS1" ]]; then
      filename="${retrievedProduct##*/}"; ext="${filename#*.}"
      # assumption is that the product has .tar extension or is already uncompressed
      if  [[ "$ext" == "tar" ]]; then
      # if tar uncompress the product
          ciop-log "INFO" "Running command: tar xf $retrievedProduct"
          tar xf $retrievedProduct
          returnCode=$?
          [ $returnCode -eq 0 ] || return ${ERR_GETPRODTYPE}
          # find the fisrt band tif product
          vrss1_b1=$(find . -name '*_1.tif')
          [[ "${vrss1_b1}" == "" ]] && return ${ERR_GETPRODTYPE}
          dir_untar_vrss1=$(dirname ${vrss1_b1})
          rm -r -f ${dir_untar_vrss1}
      else
          vrss1_b1=$(find ${retrievedProduct}/ -name '*_1.tif')
          [[ "${vrss1_b1}" == "" ]] && return ${ERR_GETPRODTYPE}
      fi
      # extract product type from product name
      vrss1_b1=$(basename ${vrss1_b1})
      l2b_test=$(echo "${vrss1_b1}" | grep "L2B")
      [[ "${l2b_test}" != "" ]] && prodTypeName="L2B" ||  return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "RapidEye" ]]; then
      # prodcut name assumed like TTTTTTT_DDDD-DD-DD_RE?_LL_HHHHHH
      # where LL is the product level
      prodTypeName=${productName:23:2}
      [[ "$prodTypeName" != "3A" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "GF2" ]]; then
      filename="${retrievedProduct##*/}"; ext="${filename#*.}"
      # assumption is that the product has .tar extension
      if  [[ "$ext" == "tar" ]]; then
          ciop-log "INFO" "Running command: tar xf $retrievedProduct *MSS2.xml"
          tar xf $retrievedProduct *MSS2.xml
          returnCode=$?
          [ $returnCode -eq 0 ] || return ${ERR_GETPRODTYPE}
          prodTypeName=$(sed -n -e 's|^.*<ProductLevel>\(.*\)</ProductLevel>$|\1|p' *MSS2.xml)
          rm -f *MSS2.xml
      else
          ciop-log "ERROR" "Failed to get product type from : ${retrievedProduct}"
          ciop-log "ERROR" "Product extension not equal to the expected"
          return $ERR_WRONGPRODTYPE
      fi
      [[ "$prodTypeName" != "LEVEL2A" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "Alos-2" ]]; then
      prodTypeName=""
      # check if ALOS2 product is a folder
      if [[ -d "${retrievedProduct}" ]]; then
          # check if ALOS2 folder contains a zip file
          ALOS_ZIP=$(ls ${retrievedProduct} | egrep '^.*ALOS2.*.zip$')
          # if doesn't contain a zip it should be already uncompressed -> search summary file into the folder
	  if [[ -z "$ALOS_ZIP" ]]; then
	      prodTypeName="$( cat ${retrievedProduct}/summary.txt | sed -n -e 's|^.*_ProcessLevel=\"\(.*\)\".*$|\1|p')"
 	    # extract summary file from compressed archive 
          else
              prodTypeName="$(unzip -p ${retrievedProduct}/$ALOS_ZIP summary.txt | sed -n -e 's|^.*_ProcessLevel=\"\(.*\)\".*$|\1|p')"
          fi
     fi
     [[ -z "$prodTypeName" ]] && ciop-log "ERROR" "Failed to get product type from : $retrievedProduct"
     [[ "$prodTypeName" != "1.5" ]] && return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "Kanopus-V" ]]; then
      mss_test=$(echo "${productName}" | grep "MSS")
      [[ "$mss_test" != "" ]] && prodTypeName="MSS"  || return $ERR_WRONGPRODTYPE
  fi

  if [[ "${mission}" == "Resurs-P" ]]; then
      prodTypeName="MSS"
  fi

  if [[ "${mission}" == "TerraSAR-X" ]]; then
      ciop-log "INFO" "Retrieving product type from TerraSAR-X product: ${retrievedProduct}"
      if [[ -d "${retrievedProduct}" ]]; then
          tsx_xml=$(find ${retrievedProduct}/ -name '*SAR*.xml' | head -1 | sed 's|^.*\/||')
	  prodTypeName="${tsx_xml:10:3}"
      elif [[ "${retrievedProduct##*.}" == "tar" ]]; then
          prodTypeName=$(tar tvf ${retrievedProduct} | sed -n -e 's|^.*\/||' -e 's|^.*_SAR__\(...\)_.*.xml$|\1|p')
      else
          ciop-log "ERROR" "Failed to get product type from : ${retrievedProduct}"
	  return $ERR_WRONGPRODTYPE
      fi
      [[ "$prodTypeName" != "EEC" ]] && return $ERR_WRONGPRODTYPE
  fi

  echo ${prodTypeName}
  return 0
}


# function that download and unzip data using the data catalougue reference
function get_data() {

  local ref=$1
  local target=$2
  local local_file
  local enclosure
  local res

  #get product url from input catalogue reference
  enclosure="$( opensearch-client -f atom "${ref}" enclosure)"
  # opensearh client doesn't deal with local paths
  res=$?
  [ $res -eq 0 ] && [ -z "${enclosure}" ] && return ${ERR_GETDATA}
  [ $res -ne 0 ] && enclosure=${ref}

  enclosure=$(echo "${enclosure}" | tail -1)

  #download data and get data name
  local_file="$( echo ${enclosure} | ciop-copy -f -O ${target} - 2> ${TMPDIR}/ciop_copy.stderr )"
  res=$?

  [ ${res} -ne 0 ] && return ${res}
  echo ${local_file}
}


# function that retrieves the mission data identifier from the product name
function mission_prod_retrieval(){
    local mission=""
    local retrievedProduct=$1
    local prod_basename=$( basename "$retrievedProduct" )

    prod_basename_substr_3=${prod_basename:0:3}
    prod_basename_substr_4=${prod_basename:0:4}
    prod_basename_substr_5=${prod_basename:0:5}
    prod_basename_substr_9=${prod_basename:0:9}
    prod_basename_substr_8=${prod_basename:0:8}
    prod_basename_substr_10=${prod_basename:0:10}

    [ "${prod_basename_substr_3}" = "S1A" ] && mission="Sentinel-1"
    [ "${prod_basename_substr_3}" = "S1B" ] && mission="Sentinel-1"
    [ "${prod_basename_substr_3}" = "S2A" ] && mission="Sentinel-2"
    [ "${prod_basename_substr_3}" = "S2B" ] && mission="Sentinel-2"
    [ "${prod_basename_substr_3}" = "S3A" ] && mission="Sentinel-3"
    [ "${prod_basename_substr_3}" = "S3B" ] && mission="Sentinel-3"
    [ "${prod_basename_substr_3}" = "K5_" ] && mission="Kompsat-5"
    [ "${prod_basename_substr_3}" = "K3_" ] && mission="Kompsat-3"
    [ "${prod_basename_substr_3}" = "LC8" ] && mission="Landsat-8"
    [ "${prod_basename_substr_4}" = "LS08" ] && mission="Landsat-8"
    [ "${prod_basename_substr_4}" = "LC08" ] && mission="Landsat-8"
    [ "${prod_basename_substr_4}" = "MSC_" ] && mission="Kompsat-2"
    [ "${prod_basename_substr_4}" = "FCGC" ] && mission="Pleiades"
    [ "${prod_basename_substr_5}" = "CHART" ] && mission="Pleiades"
    [ "${prod_basename_substr_5}" = "U2007" ] && mission="UK-DMC2"
    [ "${prod_basename_substr_5}" = "ORTHO" ] && mission="UK-DMC2"
    [ "${prod_basename_substr_10}" = "SENTINEL_2" ] && mission="Sentinel-2"

    ukdmc2_test=$(echo "${prod_basename}" | grep "UK-DMC-2")
    [ "${ukdmc2_test}" = "" ] || mission="UK-DMC-2"
    if [[ "${prod_basename_substr_8}" == "RESURS_P" ]] || [[ "${prod_basename_substr_8}" == "RESURS-P" ]] || [[ "${prod_basename_substr_8}" == "Resurs-P" ]] || [[ "${prod_basename_substr_8}" == "Resurs_P" ]] ; then
        mission="Resurs-P"
    fi
    if [[ "${prod_basename_substr_9}" == "KANOPUS_V" ]] || [[ "${prod_basename_substr_9}" == "KANOPUS-V" ]] || [[ "${prod_basename_substr_9}" == "Kanopus-V" ]] || [[ "${prod_basename_substr_9}" == "Kanopus_V" ]] ; then 
        mission="Kanopus-V"
    fi
    alos2_test=$(echo "${prod_basename}" | grep "ALOS2")
    [[ -z "${alos2_test}" ]] && alos2_test=$(ls "${retrievedProduct}" | grep "ALOS2")
    [ "${alos2_test}" = "" ] || mission="Alos-2"
    spot6_test=$(echo "${prod_basename}" | grep "SPOT6")
    [[ -z "${spot6_test}" ]] && spot6_test=$(ls "${retrievedProduct}" | grep "SPOT6")
    [ "${spot6_test}" = "" ] || mission="SPOT-6"
    spot7_test=$(echo "${prod_basename}" | grep "SPOT7")
    [[ -z "${spot7_test}" ]] && spot7_test=$(ls "${retrievedProduct}" | grep "SPOT7")
    [ "${spot7_test}" = "" ] || mission="SPOT-7"
    [ "${prod_basename_substr_3}" = "SO_" ] && mission="TerraSAR-X"
    [ "${prod_basename_substr_4}" = "dims" ] && mission="TerraSAR-X"
    [ "${prod_basename_substr_4}" = "RS2_" ] && mission="Radarsat-2"
    [ "${prod_basename_substr_3}" = "GF2" ] && mission="GF2"
    rapideye_test=${prod_basename:19:2}
    [ "${rapideye_test}" = "RE" ] && mission="RapidEye"
    vrss1_test_1=$(echo "${prod_basename}" | grep "VRSS1")
    vrss1_test_2=$(echo "${prod_basename}" | grep "VRSS-1")
    if [[ "${vrss1_test_1}" != "" ]] || [[ "${vrss1_test_2}" != "" ]]; then
        mission="VRSS1"
    fi

    if [ "${mission}" != "" ] ; then
        echo ${mission}
    else
        return ${ERR_GETMISSION}
    fi

}


# function that gets the Sentinel-1 acquisition mode from product name
function get_s1_acq_mode(){
# function call get_s1_acq_mode "${prodname}"
local prodname=$1
# filename convention assumed like S1A_AA_* where AA is the acquisition mode to be extracted
acqMode=$( echo ${prodname:4:2} )
echo ${acqMode}
return 0
}


# function that runs the gets the pixel size in meters depending on the mission data
function get_pixel_spacing() {

# function call get_pixel_size "${mission}" "${prodType}" "${retrievedProduct}"
local mission=$1
local prodType=$2
local retrievedProduct=$3
local prodname=$( basename "$retrievedProduct" )

case "$mission" in
        "Sentinel-1")
	    acqMode=$(get_s1_acq_mode "${prodname}")
	    if [ "${acqMode}" == "EW" ]; then
	        if [ "${prodType}" == "GRDH" ]; then
		    echo 25
		elif [ "${prodType}" == "GRDM" ]; then
		    echo 40
		else
		    return ${ERR_GETPIXELSPACING}	    
		fi
            elif [ "${acqMode}" == "IW" ]; then
		if [ "${prodType}" == "GRDH" ]; then
		    echo 10
                elif [ "${prodType}" == "GRDM" ]; then
		    echo 40
                else
                    return ${ERR_GETPIXELSPACING}
                fi
            else
		return ${ERR_GETPIXELSPACING}
	    fi
            ;;

        "Sentinel-2")
            echo 10
            ;;

	"Sentinel-3")
	    if [ "${prodType}" == "EFR" ]; then
		echo 300
	    elif [ "${prodType}" == "ERR" ]; then
	    	echo 1200
	    else 
		return ${ERR_GETPIXELSPACING}
	    fi
	    ;;

        "UK-DMC2")
            echo 22
            ;;

        "Kompsat-2")
            echo 4
            ;;

        "Kompsat-3")
            echo 2.8
            ;;

        "Landsat-8")
            echo 30
            ;;
        
        "Pleiades")
            echo 2
            ;;

        "Radarsat-2")
            product_xml=$(find ${retrievedProduct}/ -name 'product.xml')
            pixSpac=$( cat ${product_xml} | grep sampledPixelSpacing | sed -n -e 's|^.*<sampledPixelSpacing .*>\(.*\)</sampledPixelSpacing>|\1|p' )            
            echo  $pixSpac | awk '{ print sprintf("%.9f", $1); }'
            ;;

        SPOT-[6-7])
            spot_xml=$(find ${retrievedProduct}/ -name 'DIM_SPOT?_*MS_*.XML' )
            pixSpac=$( cat ${spot_xml} | grep RESAMPLING_SPACING | sed -n -e 's|^.*<RESAMPLING_SPACING .*>\(.*\)</RESAMPLING_SPACING>|\1|p' )
            echo  $pixSpac | awk '{ print sprintf("%.9f", $1); }'
            ;;

        "Kompsat-5")
            product_xml=$(find ${retrievedProduct}/ -name 'K5_*_Aux.xml')
            pixSpac=$( cat ${product_xml} | grep GroundRangeGeometricResolution | sed -n -e 's|^.*<GroundRangeGeometricResolution>\(.*\)</GroundRangeGeometricResolution>|\1|p' )
            echo  $pixSpac | awk '{ print sprintf("%.9f", $1); }'
            ;;

        "VRSS1")
            filename="${retrievedProduct##*/}"; ext="${filename#*.}"
            # assumption is that the product has .tar extension or is already uncompressed
            if  [[ "$ext" == "tar" ]]; then
            # if tar uncompress the product
                ciop-log "INFO" "Running command: tar xf $retrievedProduct"
                tar xf $retrievedProduct
                returnCode=$?
                [ $returnCode -eq 0 ] || return ${ERR_GETPIXELSPACING}
                # find the metadata file
                product_xml=$(find . -name 'VRSS*_L2B_*[0-9].xml')
                [[ "${product_xml}" == "" ]] && return ${ERR_GETPIXELSPACING}
                pixSpac=$( cat ${product_xml} | grep pixelSpacing | sed -n -e 's|^.*<pixelSpacing>\(.*\)</pixelSpacing>|\1|p' )
                dir_untar_product_xml=$(dirname ${product_xml})
                rm -r -f ${dir_untar_product_xml}
            else
                product_xml=$(find ${retrievedProduct}/ -name 'VRSS*_L2B_*[0-9].xml')
                [[ "${product_xml}" == "" ]] && return ${ERR_GETPIXELSPACING}
                pixSpac=$( cat ${product_xml} | grep pixelSpacing | sed -n -e 's|^.*<pixelSpacing>\(.*\)</pixelSpacing>|\1|p' )
            fi
            echo  $pixSpac | awk '{ print sprintf("%.9f", $1); }'
            ;;

        "RapidEye")
            echo 5
	    ;;

	"GF2")
	    echo 3.2
	    ;;

        "Alos-2")
            if [[ -d "${retrievedProduct}" ]]; then
                ALOS_ZIP=$(ls ${retrievedProduct} | egrep '^.*ALOS2.*.zip$')
            fi
            if [[ -z "$ALOS_ZIP" ]] ; then
            # if doesn't contain a zip it should be already uncompressed
                pixSpac="$(cat ${retrievedProduct}/summary.txt | sed -n -e 's|^.*_PixelSpacing=\"\(.*\)\".*$|\1|p')"
            # get pixel spacing from zipped archive
            else
                pixSpac="$(unzip -p ${retrievedProduct}/$ALOS_ZIP summary.txt | sed -n -e 's|^.*_PixelSpacing=\"\(.*\)\".*$|\1|p')"
                rm summary.txt
            fi
            echo  $pixSpac | awk '{ print sprintf("%.9f", $1); }'
            ;;

        "Kanopus-V")
            tif_file=$(find ${retrievedProduct} -name '*.tiff')
            tif2check=""
            # check if there are more than one tif (case when also the panchromatic product is present)
            tifProdArr=($tif_file)
            tifProdArr_num=${#tifProdArr[@]}
            if [ $tifProdArr_num -eq 0 ]; then
                ciop-log "ERROR" "No tif product found"
                return ${ERR_GETPIXELSPACING}
            elif [ $tifProdArr_num -eq 1 ]; then
                tif2check=${tif_file}
            # get multispectral product as default
            else
                let "tifProdArr_num-=1"
                for idTmp in `seq 0 $tifProdArr_num`;
                do
                    num_bands=$(get_bands_num_tif "${tifProdArr[$idTmp]}")
                    retCode=$?
                    [ $retCode -eq 0 ] || return ${retCode}
                    if [ $num_bands -gt 1 ]; then
                        tif2check=${tifProdArr[$idTmp]}
                        break
                    fi
                done
            fi
            pixSpac=$(get_pixel_spacing_tif "${tif2check}")
            retCode=$?
            [ $retCode -eq 0 ] && echo ${pixSpac} || return ${retCode}
	    ;;

        "Resurs-P")
	    tif_file=$(find ${retrievedProduct} -name '*.tiff')
            tif2check=""
            # check if there are more than one tif (case when also the panchromatic product is present)
            tifProdArr=($tif_file)
            tifProdArr_num=${#tifProdArr[@]}
            if [ $tifProdArr_num -eq 0 ]; then
                ciop-log "ERROR" "No tif product found"
                return ${ERR_GETPIXELSPACING}
            elif [ $tifProdArr_num -eq 1 ]; then
                tif2check=${tif_file}
            # get multispectral product as default
            else
                let "tifProdArr_num-=1"
                for idTmp in `seq 0 $tifProdArr_num`;
                do
                    num_bands=$(get_bands_num_tif "${tifProdArr[$idTmp]}")
                    retCode=$?
                    [ $retCode -eq 0 ] || return ${retCode}
                    if [ $num_bands -gt 1 ]; then
                        tif2check=${tifProdArr[$idTmp]}
                        break
                    fi
                done
            fi
            pixSpac=$(get_pixel_spacing_tif "${tif2check}")
            retCode=$?
            [ $retCode -eq 0 ] && echo ${pixSpac} || return ${retCode}
            ;;
        
        "TerraSAR-X")
            if [[ -d "${retrievedProduct}" ]]; then
                tsx_xml=$(find ${retrievedProduct}/ -name '*SAR*.xml' | head -1 | sed 's|^.*\/||')
		pixSpac=$(xmlstarlet sel -t -v "level1Product/productSpecific/geocodedImageInfo/geoParameter/pixelSpacing/easting" ${tsx_xml})
	    elif [[ "${retrievedProduct##*.}" == "tar" ]]; then
                mkdir temp
                tar xf ${retrievedProduct} -C temp
                tsx_xml=$(find $PWD/temp/ -name '*SAR*.xml')
                pixSpac=$(xmlstarlet sel -t -v "level1Product/productSpecific/geocodedImageInfo/geoParameter/pixelSpacing/easting" ${tsx_xml})
                rm -r -f $PWD/temp
	    else
		ciop-log "ERROR" "Failed to get pixel spacing from product: ${retrievedProduct}"
		return $ERR_GETPIXELSPACING
	    fi
            echo  $pixSpac | awk '{ print sprintf("%.9f", $1); }'
            ;;

        *)
            return ${ERR_GETPIXELSPACING}
            ;;
esac

return 0

}


# function that runs the pre processing depending on the mission data
function pre_processing() {

# function call pre_processing "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
inputNum=$#
[ "$inputNum" -ne 6 ] && return ${ERR_CALLPREPROCESS}

local prodname=$1
local mission=$2
local pixelSpacing=$3
local pixelSpacingMaster=$4
local performCropping=$5
local subsettingBoxWKT=$6

case "$mission" in
        "Sentinel-1")
            pre_processing_s1 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "Sentinel-2")
            pre_processing_s2 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

	"Sentinel-3")
            pre_processing_s3 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;
	

        "UK-DMC2")
            pre_processing_ukdmc2 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "Kompsat-2")
            pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "Kompsat-3")
            pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "Landsat-8")
            pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "VRSS1")
	    pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "Pleiades")
            pre_processing_optical_otb "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "Radarsat-2")
            pre_processing_rs2 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

	SPOT-[6-7])
            pre_processing_optical_otb "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

	"Kompsat-5")
            pre_processing_k5 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "RapidEye")
            pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;; 

	"GF2")
            pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;
 
	"Alos-2")
	    pre_processing_alos2 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "Kanopus-V")
            pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;

        "Resurs-P")
            pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;
        
        "TerraSAR-X")
            pre_processing_tsx "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            return $?
            ;;
            
        *)
            return "${ERR_CALLPREPROCESS}"
            ;;
esac

}


# function that get the list of contained bands depending on the mission data
function get_band_list(){
# function call bandListCsv=$( get_band_list "${prodname}" "${mission}" [retrievedProduct])
# check on input number 
inputNum=$#
if [ "$inputNum" -lt 2 ] && [ "$inputNum" -gt 3 ]; then
    return ${ERR_BAND_LIST}
fi
local prodname=$1
local mission=$2
local retrievedProduct=""
[ "$inputNum" -eq 3 ] && retrievedProduct=$3
local bandListCsv=""
case "$mission" in
        "Sentinel-1")
            polType=$( get_polarization_s1 "${prodname}" )
	    [[ $? -eq 0  ]] || return $?
            case "$polType" in
		"SH") 
            		bandListCsv="Sigma0_HH_db"
			;;
		"SV")
                        bandListCsv="Sigma0_VV_db"
			;;
                "DH")
                        bandListCsv="Sigma0_HH_db,Sigma0_HV_db"
                        ;;                      
 		"DV")
			bandListCsv="Sigma0_VV_db,Sigma0_VH_db"
                        ;;
	    esac
            ;;

        "Sentinel-2")
	    bandListCsv="B1,B2,B3,B4,B5,B6,B7,B8,B8A,B9,B10,B11,B12"
            ;;
	"Sentinel-3")
	    bandListCsv="Oa01_radiance,Oa02_radiance,Oa03_radiance,Oa04_radiance,Oa05_radiance,Oa06_radiance,Oa07_radiance,Oa08_radiance,Oa09_radiance,Oa10_radiance,Oa11_radiance,Oa12_radiance,Oa13_radiance,Oa14_radiance,Oa15_radiance,Oa16_radiance,Oa17_radiance,Oa18_radiance,Oa19_radiance,Oa20_radiance,Oa21_radiance"
	    ;;
        "UK-DMC2")
	    bandListCsv="NIR,Red,Green"
            ;;
         
         # Fix for ticket #7537 - reordered bands list according to KS2 product channels spec : MS1 (Green), MS2 (Blue), MS3 (NIR), MS4 
        "Kompsat-2")
	    bandListCsv="${prodname}_G,${prodname}_B,${prodname}_N,${prodname}_R"
            ;;

        "Kompsat-3")
	    bandListCsv="${prodname}_G,${prodname}_B,${prodname}_R,${prodname}_N"
            ;;

        "Landsat-8")
	    bandListCsv="${prodname}_B1,${prodname}_B2,${prodname}_B3,${prodname}_B4,${prodname}_B5,${prodname}_B6,${prodname}_B7,${prodname}_B9,${prodname}_B10,${prodname}_B11"
            ;;
        
        "Pleiades")
            bandListCsv="Red,Green,Blue,NIR"
            ;;
      
        "Radarsat-2")
            local isDualPol=0
            local isQuadPol=0
            if [[ $( echo ${prodname} | grep "HH_HV_VH_VV" ) != "" ]] ; then
                bandListCsv="Sigma0_HH_db,Sigma0_HV_db,Sigma0_VH_db,Sigma0_VV_db"
                isQuadPol=1
            elif [[ $( echo ${prodname} | grep "HH_HV" ) != "" ]] && [ $isQuadPol -eq 0 ]; then
		 bandListCsv="Sigma0_HH_db,Sigma0_HV_db"
                 isDualPol=1                
            elif [[ $( echo ${prodname} | grep "VV_VH" ) != "" ]] && [ $isQuadPol -eq 0 ]; then
                 bandListCsv="Sigma0_VV_db,Sigma0_VH_db"
                 isDualPol=1
            elif [[ $( echo ${prodname} | grep "HH" ) != "" ]] && [ $isQuadPol -eq 0 ] && [ $isDualPol -eq 0 ]; then
                 bandListCsv="Sigma0_HH_db"
            elif [[ $( echo ${prodname} | grep "VV" ) != "" ]] && [ $isQuadPol -eq 0 ] && [ $isDualPol -eq 0 ]; then
                 bandListCsv="Sigma0_VV_db"
	    fi
            ;;

        SPOT-[6-7])
            bandListCsv="Red,Green,Blue,NIR"
	    ;;

        "Kompsat-5")
            # naming convention is K5>_<YYYYMMDDhhmmss>_<tttttt>_<nnnnn>_<o>_<MM><SS>_<PP>_<LLL> where PP is the polarization
            # always single pol
            bandListCsv=${prodname:38:2}
            ;;

        "VRSS1")
            bandListCsv="${prodname}_1,${prodname}_2,${prodname}_3,${prodname}_4"
            ;;
	
        "RapidEye")
            bandListCsv="Blue,Green,Red,RE,NIR"
            ;;

	"GF2")
            bandListCsv="Blue,Green,Red,NIR"
            ;;

 	"Alos-2")
	    hh_test=""
	    hv_test=""
	    vh_test=""
	    vv_test=""
            if [[ -d "${retrievedProduct}" ]]; then
                ALOS_ZIP=$(ls ${retrievedProduct} | egrep '^.*ALOS2.*.zip$')
            fi
            # if doesn't contain a zip it should be already uncompressed
            if [[ -z "$ALOS_ZIP" ]] ; then
                hh_test=$(ls ${retrievedProduct}/*.tif | grep "IMG-HH")
                hv_test=$(ls ${retrievedProduct}/*.tif | grep "IMG-HV")
                vh_test=$(ls ${retrievedProduct}/*.tif | grep "IMG-VH")
                vv_test=$(ls ${retrievedProduct}/*.tif | grep "IMG-VV")
            # else perform check on zipped archive
            else
                hh_test=$(unzip -l ${retrievedProduct}/$ALOS_ZIP | grep "IMG-HH")
	        hv_test=$(unzip -l ${retrievedProduct}/$ALOS_ZIP | grep "IMG-HV")
	        vh_test=$(unzip -l ${retrievedProduct}/$ALOS_ZIP | grep "IMG-VH")
	        vv_test=$(unzip -l ${retrievedProduct}/$ALOS_ZIP | grep "IMG-VV")
            fi
            local isQuadPol=0
	    local isDualPol=0
	    if [[ "${hh_test}" != "" ]] && [[ "${hv_test}" != "" ]] && [[ "${vh_test}" != "" ]] && [[ "${vv_test}" != "" ]]; then
	        bandListCsv="HH,HV,VH,VV"
		isQuadPol=1
            elif [[ "${hh_test}" != "" ]] && [[ "${hv_test}" != "" ]] && [ $isQuadPol -eq 0 ]; then
		bandListCsv="HH,HV"
		isDualPol=1
	    elif [[ "${vh_test}" != "" ]] && [[ "${vv_test}" != "" ]] && [ $isQuadPol -eq 0 ]; then
		bandListCsv="VV,VH"
                isDualPol=1
	    elif [[ "${vv_test}" != "" ]] && [ $isQuadPol -eq 0 ] && [ $isDualPol -eq 0 ]; then
		bandListCsv="VV"
	    elif [[ "${hh_test}" != "" ]] && [ $isQuadPol -eq 0 ] && [ $isDualPol -eq 0 ]; then
		bandListCsv="HH"
	    fi
            ;;

        "Kanopus-V")
            tif_file=$(find ${retrievedProduct} -name '*.tiff')
            tif2check=""
            # check if there are more than one tif (case when also the panchromatic product is present)
            tifProdArr=($tif_file)
            tifProdArr_num=${#tifProdArr[@]}
            if [ $tifProdArr_num -eq 0 ]; then
                ciop-log "ERROR" "No tif product found"
                return ${ERR_GETPIXELSPACING}
            elif [ $tifProdArr_num -eq 1 ]; then
                tif2check=${tif_file}
            # get multispectral product as default
            else
                let "tifProdArr_num-=1"
                for idTmp in `seq 0 $tifProdArr_num`;
                do
                    num_bands=$(get_bands_num_tif "${tifProdArr[$idTmp]}")
                    retCode=$?
                    [ $retCode -eq 0 ] || return ${retCode}
                    if [ $num_bands -gt 1 ]; then
                        tif2check=${tifProdArr[$idTmp]}
                        break
                    fi
                done
            fi
            bandsNum=$(get_bands_num_tif "${tif2check}")
            retCode=$?
            [ $retCode -eq 0 ] || return ${retCode}
            if [ $bandsNum -eq 1 ]; then
                bandListCsv="PAN"
            elif [ $bandsNum -eq 4 ]; then
                bandListCsv="Blue,Green,Red,NIR"
            else
                return "${ERR_BAND_LIST}"
            fi
            ;;

        "Resurs-P")
            tif_file=$(find ${retrievedProduct} -name '*.tiff')
            # check if there are more than one tif (case when also the panchromatic product is present)
            tifProdArr=($tif_file)
            tifProdArr_num=${#tifProdArr[@]}
            if [ $tifProdArr_num -eq 0 ]; then
                ciop-log "ERROR" "No tif product found"
                return ${ERR_GETPIXELSPACING}
            elif [ $tifProdArr_num -eq 1 ]; then
                tif2check=${tif_file}
            # get multispectral product as default
            else
                let "tifProdArr_num-=1"
                for idTmp in `seq 0 $tifProdArr_num`;
                do
                    num_bands=$(get_bands_num_tif "${tifProdArr[$idTmp]}")
                    retCode=$?
                    [ $retCode -eq 0 ] || return ${retCode}
                    if [ $num_bands -gt 1 ]; then
                        tif2check=${tifProdArr[$idTmp]}
                        break
                    fi
                done
            fi
            bandsNum=$(get_bands_num_tif "${tif2check}")
            retCode=$?
            [ $retCode -eq 0 ] || return ${retCode} 
            if [ $bandsNum -eq 1 ]; then
                bandListCsv="PAN"
            elif [ $bandsNum -eq 4 ]; then
                bandListCsv="Blue,Green,Red,NIR"
            elif [ $bandsNum -eq 5 ]; then
                bandListCsv="Blue,Green,Red,Red_Edge,NIR"
            else
                return "${ERR_BAND_LIST}"
            fi
            ;;

        "TerraSAR-X")
            if [[ -d "${retrievedProduct}" ]]; then
                tsx_xml=$(find ${retrievedProduct}/ -name '*SAR*.xml' | head -1 | sed 's|^.*\/||')
                pol=$(xmlstarlet sel -t -v "level1Product/productQuality/rawDataQuality/polarization" ${tsx_xml})
            elif [[ "${retrievedProduct##*.}" == "tar" ]]; then
                mkdir temp
                tar xf ${retrievedProduct} -C temp
                tsx_xml=$(find $PWD/temp/ -name '*SAR*.xml')
                pol=$(xmlstarlet sel -t -v "level1Product/productQuality/rawDataQuality/polarization" ${tsx_xml})
                rm -r -f $PWD/temp
            else
                ciop-log "ERROR" "Failed to get band list from product: ${retrievedProduct}"
                return $ERR_BAND_LIST
            fi
            bandListCsv=$pol
            ;;

        *)
            return "${ERR_BAND_LIST}"
            ;;
esac
echo ${bandListCsv}
return 0
}


# getter of band identifier 
function get_band_id(){
# function call $(get_band_id ${band_name} ${bandListCsv})
local band_name=$1
local bandListCsv=$2
#get band index (band_name assumed to be like band_NN where NN is the band index)
bandIndex=$(echo "${band_name}" | sed -n -e 's|^.*band_\(.*\)|\1|p')
[ -z "${bandIndex}" ] && return $ERR_BAND_ID_GET
# convert band from comma separted values to space separated values
bandListSsv=$( echo "${bandListCsv}" | sed 's|,| |g' )
[ -z "${bandListSsv}" ] && return $ERR_BAND_ID_GET
#get band name from space separated values in position given by band index
bandIdentifier=$( echo ${bandListSsv} | tr '\t' ' ' | tr -s ' ' | cut -d ' ' -f $bandIndex )
[ -z "${bandIdentifier}" ] && return $ERR_BAND_ID_GET

echo $bandIdentifier
return 0
    
}


# function that checks if band index exceeds the number of available bands within input product   
function check_band_id() {
# function call check_band_id ${band_name} ${bandListCsv}
local band_name=$1
local bandListCsv=$2
#get band index (band_name assumed to be like band_NN where NN is the band index)
bandIndex=$(echo "${band_name}" | sed -n -e 's|^.*band_\(.*\)|\1|p')
[ -z "${bandIndex}" ] && return $ERR_BAND_ID
# convert band from comma separted values to space separated values
bandListSsv=$( echo "${bandListCsv}" | sed 's|,| |g' )
[ -z "${bandListSsv}" ] && return $ERR_BAND_ID
declare -a bandListArray=(${bandListSsv})
# get number of bands
numBands=${#bandListArray[@]} 
[ $bandIndex -gt $numBands ] && return $ERR_BAND_ID || return 0

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


# function that computes the Multilook factor from target pixel spacing (i.e. master) and current one
function get_ml_factor() {

# function call get_ml_factor ${pixelSpacing} ${pixelSpacingMaster}

pixelSpacing=$1
pixelSpacingMaster=$2
local ml_factor=""

# if current pixel spacing is higher or equal to target one --> skip multilook
if (( $(bc <<< "$pixelSpacing >= $pixelSpacingMaster") )) ; then

    # skip multilook --> factor = 1
    ml_factor=1

# if current pixel spacing is lower or equal to target one --> do multilook
elif (( $(bc <<< "$pixelSpacing < $pixelSpacingMaster") )) ; then

    # multilook to be performed --> factor = floor($pixelSpacingMaster / $pixelSpacing)
    ml_factor=$(echo "scale=0; $pixelSpacingMaster / $pixelSpacing" | bc)

fi

echo $ml_factor


}


# function that compares the pixel spacing and returns the greter one
function get_greater_pixel_spacing() {

# function call get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster}

pixelSpacing=$1
pixelSpacingMaster=$2
local out_spacing=""

# if current pixel spacing is higher or equal to target one --> return current pixel spacing
if (( $(bc <<< "$pixelSpacing >= $pixelSpacingMaster") )) ; then

    out_spacing=$pixelSpacing

# if current pixel spacing is lower or equal to target one --> return master pixel spacing
elif (( $(bc <<< "$pixelSpacing < $pixelSpacingMaster") )) ; then

    out_spacing=$pixelSpacingMaster

fi

echo $out_spacing


}


# Sentinel-1 pre processing function
function pre_processing_s1() {
# function call pre_processing_s1 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 5 ] && return ${ERR_PREPROCESS}

local retrievedProduct=$1
local pixelSpacing=$2
local pixelSpacingMaster=$3
local performCropping=$4
local subsettingBoxWKT=$5
local prodname=""

# get S1 product name removing extension
local s1_basename=$(basename "${retrievedProduct}")
prodname="${s1_basename%.*}"
ciop-log "DEBUG" "s1_prodname ${prodname}"

# get s1 manifest path
s1_manifest=$(find ${retrievedProduct}/ -name 'manifest.safe')
ciop-log "DEBUG" "s1_manifest ${s1_manifest}"

outProdBasename=$(basename ${prodname})_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}
ml_factor=$( get_ml_factor "${pixelSpacing}" "${pixelSpacingMaster}" )
# the log entry is available in the process stderr
ciop-log "DEBUG" "ml_factor: ${ml_factor}"

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for Sentinel 1 data pre processing"

# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_pre_processing_s1 "${s1_manifest}" "${ml_factor}" "${pixelSpacing}" "${performCropping}" "${subsettingBoxWKT}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"

# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for Sentinel 1 data pre processing"

# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    rm log.txt
    # no error case
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        # error due to void intersection between user AOI and data
        return $ERR_AOI
    else
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        # generic snap-gpt execution error
        return $ERR_SNAP
    fi
fi

}


function create_snap_request_pre_processing_s1() {

# function call create_snap_request_pre_processing_s1 "${prodname}" "${ml_factor}" "${pixelSpacing}" "${performCropping}" "${subsettingBoxWKT}" "${outProd}"

# function which creates the actual request from
# a template and returns the path to the request

inputNum=$#
[ "$inputNum" -ne 6 ] && return ${ERR_PREPROCESS}

local prodname=$1
local ml_factor=$2
local srcPixelSpacing=$3
local performCropping=$4
local subsettingBoxWKT=$5
local outprod=$6

local commentSbsBegin=""
local commentSbsEnd=""
local commentMlBegin=""
local commentMlEnd=""
local commentCalSrcBegin=""
local commentCalSrcEnd=""
local commentDbSrcBegin=""
local commentDbSrcEnd=""

local beginCommentXML="<!--"
local endCommentXML="-->"


if [ "${performCropping}" = false ] ; then
    commentSbsBegin="${beginCommentXML}"
    commentSbsEnd="${endCommentXML}"
else
    commentDbSrcBegin="${beginCommentXML}"
    commentDbSrcEnd="${endCommentXML}"
fi

if [ "$ml_factor" -eq 1 ] ; then
    commentMlBegin="${beginCommentXML}"
    commentMlEnd="${endCommentXML}"
else
    commentCalSrcBegin="${beginCommentXML}"
    commentCalSrcEnd="${endCommentXML}"
fi
#compute pixel spacing according to the multilook factor
pixelSpacing=$(echo "scale=1; $srcPixelSpacing*$ml_factor" | bc )
#sets the output filename
snap_request_filename="${TMPDIR}/$( uuidgen ).xml"

   cat << EOF > ${snap_request_filename}
<graph id="Graph">
<version>1.0</version>
  <node id="Read">
    <operator>Read</operator>
    <sources/>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${prodname}</file>
      <formatName>SENTINEL-1</formatName>
    </parameters>
  </node>
  <node id="Remove-GRD-Border-Noise">
    <operator>Remove-GRD-Border-Noise</operator>
    <sources>
      <sourceProduct refid="Read"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <selectedPolarisations/>
      <borderLimit>1000</borderLimit>
      <trimThreshold>0.5</trimThreshold>
    </parameters>
  </node>
  <node id="Calibration">
    <operator>Calibration</operator>
    <sources>
      <sourceProduct refid="Remove-GRD-Border-Noise"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <auxFile>Product Auxiliary File</auxFile>
      <externalAuxFile/>
      <outputImageInComplex>false</outputImageInComplex>
      <outputImageScaleInDb>false</outputImageScaleInDb>
      <createGammaBand>false</createGammaBand>
      <createBetaBand>false</createBetaBand>
      <selectedPolarisations/>
      <outputSigmaBand>true</outputSigmaBand>
      <outputGammaBand>false</outputGammaBand>
      <outputBetaBand>false</outputBetaBand>
    </parameters>
  </node>
${commentMlBegin}  <node id="Multilook">
    <operator>Multilook</operator>
    <sources>
      <sourceProduct refid="Calibration"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <nRgLooks>${ml_factor}</nRgLooks>
      <nAzLooks>${ml_factor}</nAzLooks>
      <outputIntensity>true</outputIntensity>
      <grSquarePixel>true</grSquarePixel>
    </parameters>
  </node> ${commentMlEnd}
  <node id="Terrain-Correction">
    <operator>Terrain-Correction</operator>
    <sources>
      ${commentMlBegin} <sourceProduct refid="Multilook"/> ${commentMlEnd}
      ${commentCalSrcBegin} <sourceProduct refid="Calibration"/> ${commentCalSrcEnd}
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <demName>SRTM 3Sec</demName>
      <externalDEMFile/>
      <externalDEMNoDataValue>0.0</externalDEMNoDataValue>
      <externalDEMApplyEGM>true</externalDEMApplyEGM>
      <demResamplingMethod>BILINEAR_INTERPOLATION</demResamplingMethod>
      <imgResamplingMethod>BILINEAR_INTERPOLATION</imgResamplingMethod>
      <pixelSpacingInMeter>${pixelSpacing}</pixelSpacingInMeter>
      <!-- <pixelSpacingInDegree>8.983152841195215E-5</pixelSpacingInDegree> -->
      <mapProjection>WGS84(DD)</mapProjection>
      <nodataValueAtSea>false</nodataValueAtSea>
      <saveDEM>false</saveDEM>
      <saveLatLon>false</saveLatLon>
      <saveIncidenceAngleFromEllipsoid>false</saveIncidenceAngleFromEllipsoid>
      <saveLocalIncidenceAngle>false</saveLocalIncidenceAngle>
      <saveProjectedLocalIncidenceAngle>false</saveProjectedLocalIncidenceAngle>
      <saveSelectedSourceBand>true</saveSelectedSourceBand>
      <outputComplex>false</outputComplex>
      <applyRadiometricNormalization>false</applyRadiometricNormalization>
      <saveSigmaNought>false</saveSigmaNought>
      <saveGammaNought>false</saveGammaNought>
      <saveBetaNought>false</saveBetaNought>
      <incidenceAngleForSigma0>Use projected local incidence angle from DEM</incidenceAngleForSigma0>
      <incidenceAngleForGamma0>Use projected local incidence angle from DEM</incidenceAngleForGamma0>
      <auxFile>Latest Auxiliary File</auxFile>
      <externalAuxFile/>
    </parameters>
  </node>
  <node id="LinearToFromdB">
    <operator>LinearToFromdB</operator>
    <sources>
      <sourceProduct refid="Terrain-Correction"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
    </parameters>
  </node>
  <node id="Apply-Orbit-File">
    <operator>Apply-Orbit-File</operator>
    <sources>
      <sourceProduct refid="Read"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <orbitType>Sentinel Precise (Auto Download)</orbitType>
      <polyDegree>3</polyDegree>
      <continueOnFail>true</continueOnFail>
    </parameters>
  </node>
${commentSbsBegin}  <node id="Subset">
    <operator>Subset</operator>
    <sources>
      <sourceProduct refid="LinearToFromdB"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <region/>
      <geoRegion>${subsettingBoxWKT}</geoRegion>
      <subSamplingX>1</subSamplingX>
      <subSamplingY>1</subSamplingY>
      <fullSwath>false</fullSwath>
      <tiePointGridNames/>
      <copyMetadata>true</copyMetadata>
    </parameters>
  </node>  ${commentSbsEnd}
  <node id="Write">
    <operator>Write</operator>
    <sources>
      ${commentSbsBegin} <sourceProduct refid="Subset"/> ${commentSbsEnd}
      ${commentDbSrcBegin} <sourceProduct refid="LinearToFromdB"/> ${commentDbSrcEnd}
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outprod}.dim</file>
      <formatName>BEAM-DIMAP</formatName>
    </parameters>
  </node>
  <applicationData id="Presentation">
    <Description/>
    <node id="Read">
            <displayPosition x="9.0" y="128.0"/>
    </node>
    <node id="Calibration">
      <displayPosition x="200.0" y="129.0"/>
    </node>
    <node id="Multilook">
          <displayPosition x="291.0" y="129.0"/>
    </node>
    <node id="Terrain-Correction">
      <displayPosition x="480.0" y="129.0"/>
    </node>
    <node id="LinearToFromdB">
      <displayPosition x="623.0" y="129.0"/>
    </node>
    <node id="Apply-Orbit-File">
      <displayPosition x="88.0" y="129.0"/>
    </node>
    <node id="Subset">
      <displayPosition x="751.0" y="127.0"/>
    </node>
    <node id="Write">
                <displayPosition x="850.0" y="129.0"/>
    </node>
  </applicationData>
</graph>
EOF

    [ $? -eq 0 ] && {
        echo "${snap_request_filename}"
        return 0
    } || return ${SNAP_REQUEST_ERROR}
}


# Radarsat-2 pre processing function
function pre_processing_rs2() {
# function call pre_processing_rs2 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 5 ] && return ${ERR_PREPROCESS}

local retrievedProduct=$1
local pixelSpacing=$2
local pixelSpacingMaster=$3
local performCropping=$4
local subsettingBoxWKT=$5
local prodname=""
local product_xml=""
unzippedFolder=$(ls $retrievedProduct)
# log the value, it helps debugging.
# the log entry is available in the process stderr
ciop-log "DEBUG" "unzippedFolder: ${unzippedFolder}"
# retrieved product pointing to the unzipped folder
prodname=$retrievedProduct/$unzippedFolder
product_xml=$(find ${retrievedProduct}/ -name 'product.xml')
outProdBasename=$(basename ${prodname})_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}
ml_factor=$( get_ml_factor "${pixelSpacing}" "${pixelSpacingMaster}" )
# the log entry is available in the process stderr
ciop-log "DEBUG" "ml_factor: ${ml_factor}"

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for Radarsat 2 data pre processing"

# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_pre_processing_rs2 "${product_xml}" "${ml_factor}" "${pixelSpacing}" "${performCropping}" "${subsettingBoxWKT}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"

# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for Radarsat 2 data pre processing"

# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    rm log.txt
    # no error case
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        # error due to void intersection between user AOI and data
        return $ERR_AOI
    else
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        # generic snap-gpt execution error
        return $ERR_SNAP
    fi
fi

}


function create_snap_request_pre_processing_rs2() {

# function call create_snap_request_pre_processing_rs2 "${prodname}" "${ml_factor}" "${pixelSpacing}" "${performCropping}" "${subsettingBoxWKT}" "${outProd}"

# function which creates the actual request from
# a template and returns the path to the request

inputNum=$#
[ "$inputNum" -ne 6 ] && return ${ERR_PREPROCESS}

local prodname=$1
local ml_factor=$2
local srcPixelSpacing=$3
local performCropping=$4
local subsettingBoxWKT=$5
local outprod=$6

local commentSbsBegin=""
local commentSbsEnd=""
local commentMlBegin=""
local commentMlEnd=""
local commentCalSrcBegin=""
local commentCalSrcEnd=""
local commentDbSrcBegin=""
local commentDbSrcEnd=""

local beginCommentXML="<!--"
local endCommentXML="-->"


if [ "${performCropping}" = false ] ; then
    commentSbsBegin="${beginCommentXML}"
    commentSbsEnd="${endCommentXML}"
else
    commentDbSrcBegin="${beginCommentXML}"
    commentDbSrcEnd="${endCommentXML}"
fi

if [ "$ml_factor" -eq 1 ] ; then
    commentMlBegin="${beginCommentXML}"
    commentMlEnd="${endCommentXML}"
else
    commentCalSrcBegin="${beginCommentXML}"
    commentCalSrcEnd="${endCommentXML}"
fi
#compute pixel spacing according to the multilook factor
pixelSpacing=$(echo "scale=1; $srcPixelSpacing*$ml_factor" | bc )
#sets the output filename
snap_request_filename="${TMPDIR}/$( uuidgen ).xml"

   cat << EOF > ${snap_request_filename}
<graph id="Graph">
  <version>1.0</version>
  <node id="Read">
    <operator>Read</operator>
    <sources/>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${prodname}</file>
    </parameters>
  </node>
  <node id="Calibration">
    <operator>Calibration</operator>
    <sources>
      <sourceProduct refid="Read"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <auxFile>Product Auxiliary File</auxFile>
      <externalAuxFile/>
      <outputImageInComplex>false</outputImageInComplex>
      <outputImageScaleInDb>false</outputImageScaleInDb>
      <createGammaBand>false</createGammaBand>
      <createBetaBand>false</createBetaBand>
      <selectedPolarisations/>
      <outputSigmaBand>true</outputSigmaBand>
      <outputGammaBand>false</outputGammaBand>
      <outputBetaBand>false</outputBetaBand>
    </parameters>
  </node>
${commentMlBegin}  <node id="Multilook">
    <operator>Multilook</operator>
    <sources>
      <sourceProduct refid="Calibration"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <nRgLooks>${ml_factor}</nRgLooks>
      <nAzLooks>${ml_factor}</nAzLooks>
      <outputIntensity>true</outputIntensity>
      <grSquarePixel>true</grSquarePixel>
    </parameters>
  </node> ${commentMlEnd}
  <node id="Terrain-Correction">
    <operator>Terrain-Correction</operator>
    <sources>
${commentMlBegin}  <sourceProduct refid="Multilook"/> ${commentMlEnd}
${commentCalSrcBegin}  <sourceProduct refid="Calibration"/> ${commentCalSrcEnd}
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <demName>SRTM 3Sec</demName>
      <externalDEMFile/>
      <externalDEMNoDataValue>0.0</externalDEMNoDataValue>
      <externalDEMApplyEGM>true</externalDEMApplyEGM>
      <demResamplingMethod>BILINEAR_INTERPOLATION</demResamplingMethod>
      <imgResamplingMethod>BILINEAR_INTERPOLATION</imgResamplingMethod>
      <pixelSpacingInMeter>${pixelSpacing}</pixelSpacingInMeter>
      <!-- <pixelSpacingInDegree>2.2457882102988038E-4</pixelSpacingInDegree> -->
      <mapProjection>GEOGCS[&quot;WGS84(DD)&quot;, &#xd;
  DATUM[&quot;WGS84&quot;, &#xd;
    SPHEROID[&quot;WGS84&quot;, 6378137.0, 298.257223563]], &#xd;
  PRIMEM[&quot;Greenwich&quot;, 0.0], &#xd;
  UNIT[&quot;degree&quot;, 0.017453292519943295], &#xd;
  AXIS[&quot;Geodetic longitude&quot;, EAST], &#xd;
  AXIS[&quot;Geodetic latitude&quot;, NORTH]]</mapProjection>
      <nodataValueAtSea>false</nodataValueAtSea>
      <saveDEM>false</saveDEM>
      <saveLatLon>false</saveLatLon>
      <saveIncidenceAngleFromEllipsoid>false</saveIncidenceAngleFromEllipsoid>
      <saveLocalIncidenceAngle>false</saveLocalIncidenceAngle>
      <saveProjectedLocalIncidenceAngle>false</saveProjectedLocalIncidenceAngle>
      <saveSelectedSourceBand>true</saveSelectedSourceBand>
      <outputComplex>false</outputComplex>
      <applyRadiometricNormalization>false</applyRadiometricNormalization>
      <saveSigmaNought>false</saveSigmaNought>
      <saveGammaNought>false</saveGammaNought>
      <saveBetaNought>false</saveBetaNought>
      <incidenceAngleForSigma0>Use projected local incidence angle from DEM</incidenceAngleForSigma0>
      <incidenceAngleForGamma0>Use projected local incidence angle from DEM</incidenceAngleForGamma0>
      <auxFile>Latest Auxiliary File</auxFile>
      <externalAuxFile/>
    </parameters>
  </node>
  <node id="LinearToFromdB">
    <operator>LinearToFromdB</operator>
    <sources>
      <sourceProduct refid="Terrain-Correction"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
    </parameters>
  </node>
${commentSbsBegin}  <node id="Subset">
    <operator>Subset</operator>
    <sources>
      <sourceProduct refid="LinearToFromdB"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <region/>
      <geoRegion>${subsettingBoxWKT}</geoRegion>
      <subSamplingX>1</subSamplingX>
      <subSamplingY>1</subSamplingY>
      <fullSwath>false</fullSwath>
      <tiePointGridNames/>
      <copyMetadata>true</copyMetadata>
    </parameters>
  </node>  ${commentSbsEnd}
  <node id="Write">
    <operator>Write</operator>
    <sources>
      ${commentSbsBegin} <sourceProduct refid="Subset"/> ${commentSbsEnd}
      ${commentDbSrcBegin} <sourceProduct refid="LinearToFromdB"/> ${commentDbSrcEnd}
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outprod}.dim</file>
      <formatName>BEAM-DIMAP</formatName>
    </parameters>
  </node>
  <applicationData id="Presentation">
    <Description/>
    <node id="Read">
            <displayPosition x="37.0" y="134.0"/>
    </node>
    <node id="Calibration">
      <displayPosition x="118.0" y="135.0"/>
    </node>
    <node id="Multilook">
      <displayPosition x="211.0" y="135.0"/>
    </node>
    <node id="Terrain-Correction">
      <displayPosition x="300.0" y="135.0"/>
    </node>
    <node id="LinearToFromdB">
      <displayPosition x="454.0" y="134.0"/>
    </node>
    <node id="Write">
            <displayPosition x="628.0" y="137.0"/>
    </node>
  </applicationData>
</graph>
EOF

    [ $? -eq 0 ] && {
        echo "${snap_request_filename}"
        return 0
    } || return ${SNAP_REQUEST_ERROR}
}


# Sentinel-2 pre processing function
function pre_processing_s2() {
# function call pre_processing_s2 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 5 ] && return ${ERR_PREPROCESS}

local retrievedProduct=$1
local pixelSpacing=$2
local pixelSpacingMaster=$3
local performCropping=$4
local subsettingBoxWKT=$5
local prodname=""
unzippedFolder=$(ls $retrievedProduct)
# log the value, it helps debugging.
# the log entry is available in the process stderr
ciop-log "DEBUG" "unzippedFolder: ${unzippedFolder}"
# retrieved product pointing to the unzipped folder
prodname=$retrievedProduct/$unzippedFolder

#get full path of S2 product metadata xml file
# check if it is like S2?_*.xml
# s2_xml=$(ls "${retrievedProduct}"/S2?_*.xml )
s2_xml=$(find ${prodname}/ -name '*.xml' | egrep '^.*/S2[A-Z]?_.*.SAFE/S2[A-Z]?_[A-Z0-9]*.xml$')
# if it not like S2?_*.xml
if [ $? -ne 0 ] ; then
    # check if it is like MTD_*.xml
    #s2_xml=$(ls "${retrievedProduct}"/MTD_*.xml )
    s2_xml=$(find ${prodname}/ -name '*.xml' | egrep '^.*/S2[A-Z]?_.*.SAFE/MTD_[A-Z0-9]*.xml$')
    #if it is neither like MTD_*.xml: return error
    [ $? -ne 0 ] && return $ERR_GETPRODMTD
fi

# use the greter pixel spacing as target spacing (in order to downsample if needed, upsampling always avoided)
local target_spacing=$( get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster} )

prodBasename=$(basename ${prodname})
outProdBasename=${prodBasename}_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for Sentinel 2 data pre processing"
# source bands list for Sentinel 2
sourceBandsList=$(get_band_list "${prodBasename}" "Sentinel-2" )
# resample flag always true because S2 contains bands with differnt sampling steps
performResample="true"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rsmpl_rprj_sbs "${s2_xml}" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"

# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for Sentinel 2 data pre processing"

# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
rm log.txt
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    # no error case
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        # error due to void intersection between user AOI and data
        return $ERR_AOI
    else
        # generic snap-gpt execution error
        return $ERR_SNAP
    fi
fi

}

function pre_processing_s3() {
# function call pre_processing_s3 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 5 ] && return ${ERR_PREPROCESS}

local retrievedProduct=$1
local pixelSpacing=$2
local pixelSpacingMaster=$3
local performCropping=$4
local subsettingBoxWKT=$5
local prodname=""
unzippedFolder=$(ls $retrievedProduct)
# log the value, it helps debugging.
# the log entry is available in the process stderr
ciop-log "DEBUG" "unzippedFolder: ${unzippedFolder}"
# retrieved product pointing to the unzipped folder
prodname=$retrievedProduct/$unzippedFolder

#get full path of S3 product metadata xml file
# check if it is like S3?_*.xml
s3_xml=$(find ${prodname}/ -name '*.xml')

# use the greter pixel spacing as target spacing (in order to downsample if needed, upsampling always avoided)
local target_spacing=$( get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster} )

prodBasename=$(basename ${prodname})
outProdBasename=${prodBasename}_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for Sentinel 3 data pre processing"
# source bands list for Sentinel 2
sourceBandsList=$(get_band_list "${prodBasename}" "Sentinel-3" )
# resample flag always true because S2 contains bands with differnt sampling steps
performResample="true"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rsmpl_rprj_sbs_s3 "${s3_xml}" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"

# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for Sentinel 3 data pre processing"

# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
rm log.txt
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    # no error case
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        # error due to void intersection between user AOI and data
        return $ERR_AOI
    else
        # generic snap-gpt execution error
        return $ERR_SNAP
    fi
fi

}

# UKDMC2 pre processing function
function pre_processing_ukdmc2() {
# function call pre_processing_ukdmc2 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 5 ] && return ${ERR_PREPROCESS}

local prodname=$1
local pixelSpacing=$2
local pixelSpacingMaster=$3
local performCropping=$4
local subsettingBoxWKT=$5

# use the greter pixel spacing as target spacing (in order to downsample if needed, upsampling always avoided)
local target_spacing=$( get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster} )
# check for resampling operator: to be used only if the resolution is differenet from the current product one
local performResample=""
if (( $(bc <<< "$target_spacing != $pixelSpacing") )) ; then
    performResample="true"
else
    performResample="false"
fi
prodBasename=$(basename ${prodname})
prodDIM=$(find ${prodname} -name '*.dim')
outProdBasename=${prodBasename}_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for UK-DMC 2 data pre processing"
# source bands list for UKDMC-2
sourceBandsList=$(get_band_list "${prodBasename}" "UK-DMC2" ) 
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rsmpl_rprj_sbs "${prodDIM}" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"

# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for UK-DMC 2 data pre processing"

# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
rm log.txt
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    # no error case
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        # error due to void intersection between user AOI and data
        return $ERR_AOI
    else
        # generic snap-gpt execution error
        return $ERR_SNAP
    fi
fi

}


# Optical pre processing function with otb calibration
function pre_processing_optical_otb() {
# function call pre_processing_optical_otb "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 6 ] && return ${ERR_PREPROCESS}

local prodname=$1
local mission=$2
local pixelSpacing=$3
local pixelSpacingMaster=$4
local performCropping=$5
local subsettingBoxWKT=$6
local index=0
prodBasename=$(basename ${prodname})
local imgFile=""
# Get multispectral image file
if [ ${mission} = "Pleiades" ]; then 
    imgFile=$(find ${prodname}/ -name 'IMG_*MS_*_R1C1.JP2')
elif [ ${mission} = "SPOT-6" ] || [ ${mission} = "SPOT-7" ]; then
    imgFile=$(find ${prodname}/ -name 'IMG_SPOT?_*MS_*_R1C1.JP2')
fi
# set output calibrated filename
outputCal="${imgFile##*/}"; outputCal="${outputCal%.JP2}.tif"
#run OTB optical calibration
ciop-log "INFO" "Invoking OTB for optical calibration"
otbcli_OpticalCalibration -in ${imgFile} -out ${outputCal} -ram ${RAM_AVAILABLE}
outputCalDIM="${outputCal%.tif}.dim"
# convert tif to beam dimap format
ciop-log "INFO" "Invoking SNAP-pconvert on the generated request file for tif to dim conversion"
pconvert -f dim ${outputCal}
# remove intermediate calibrated file
rm ${outputCal}
currentBandsList=$( xmlstarlet sel -t -v "/Dimap_Document/Image_Interpretation/Spectral_Band_Info/BAND_NAME" ${outputCalDIM} )
currentBandsList=(${currentBandsList})
currentBandsList_num=${#currentBandsList[@]}
currentBandsListTXT=${TMPDIR}/currentBandsList.txt
# loop on band names to fill band list
let "currentBandsList_num-=1"
for index in `seq 0 $currentBandsList_num`;
do
    if [ $index -eq 0  ] ; then
        echo ${currentBandsList[${index}]} > ${currentBandsListTXT}
    else
        echo  ${currentBandsList[${index}]} >> ${currentBandsListTXT}
    fi
done
# loop over known product bands to fill target bands list
targetBandsNamesListTXT=${TMPDIR}/targetBandsNamesList.txt
# source bands list for Pleiades
sourceBandsList=$(get_band_list "${prodBasename}" "${mission}" )
# convert band from comma separted values to space separated values
bandListSsv=$( echo "${sourceBandsList}" | sed 's|,| |g' )
# convert ssv to array
declare -a bandListArray=(${bandListSsv})
# get number of bands
numBands=${#bandListArray[@]}
local bid=0
let "numBands-=1"
for bid in `seq 0 $numBands`; do
    if [ $bid -eq 0  ] ; then
        echo ${bandListArray[$bid]} > ${targetBandsNamesListTXT}
    else
        echo ${bandListArray[$bid]} >> ${targetBandsNamesListTXT}
    fi
done
# build request file for rename all the bands contained into the product
# report activity in the log
outProdRename=${TMPDIR}/output_cal_renamed_bands
ciop-log "INFO" "Preparing SNAP request file for bands renaming"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rename_all_bands "${outputCalDIM}" "${currentBandsListTXT}" "${targetBandsNamesListTXT}" "${outProdRename}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file bands renaming"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
# remove temp calibrated file product in beam dimap
rm -rf "${outputCalDIM%.dim}.d*"

# use the greter pixel spacing as target spacing (in order to downsample if needed, upsampling always avoided)
local target_spacing=$( get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster} )
# check for resampling operator: to be used only if the resolution is differenet from the current product one
local performResample=""
if (( $(bc <<< "$target_spacing != $pixelSpacing") )) ; then
    performResample="true"
else
    performResample="false"
fi
outProdBasename=${prodBasename}_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for optical data pre processing"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rsmpl_rprj_sbs "${outProdRename}.dim" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for optical data pre processing"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
rm -rf ${outProdRename}.d* ${targetBandsNamesListTXT}
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    # no error case
    rm log.txt
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        # error due to void intersection between user AOI and data
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        return $ERR_AOI
    else
        # generic snap-gpt execution error
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        return $ERR_SNAP
    fi
fi

}

# generic optical mission (not fully supported by SNAP) pre processing function
function pre_processing_generic_optical() {

# function call pre_processing_generic_optical "${prodname}" "${mission}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 6 ] && return ${ERR_PREPROCESS}

local prodname=$1
local mission=$2
local pixelSpacing=$3
local pixelSpacingMaster=$4
local performCropping=$5
local subsettingBoxWKT=$6

# loop to fill contained TIFs and their basenames
local tifList=${TMPDIR}/tifList.txt
local filesListCSV=""
targetBandsNamesListTXT=${TMPDIR}/targetBandsNamesList.txt
local index=0
inputProdBasenameNoExt=""
# mission dependent TIF list
# if Landsat-8 it can be compressed in tar.bz
if [ ${mission} = "Landsat-8" ]; then
    #Check if downloaded product is compressed and extract it (in tar.bz is not automatically extracted, otherwise yes)
    ext="${prodname##*/}"; ext="${ext#*.}"
    ciop-log "INFO" "Product extension is: $ext"
    if [[ "$ext" == "tar.bz" ]]; then
        ciop-log "INFO" "Extracting $prodname"
        currentBasename=$(basename $prodname)
        currentBasename="${currentBasename%%.*}"
        mkdir -p ${prodname%/*}/${currentBasename}
        cd ${prodname%/*}
        filename="${prodname##*/}"
        tar xjf $filename -C ${currentBasename}
        returnCode=$?
        [ $returnCode -eq 0 ] || return ${ERR_UNPACKING}
        prodname=${prodname%/*}/${currentBasename}
        ls "${prodname}"/LC8*_B[1-7].TIF > $tifList
        ls "${prodname}"/LC8*_B9.TIF >> $tifList
        ls "${prodname}"/LC8*_B1[0,1].TIF >> $tifList
    elif [[ "$ext" == "tar" ]]; then
        ciop-log "INFO" "Extracting $prodname"
        currentBasename=$(basename $prodname)
        currentBasename="${currentBasename%%.*}"
        mkdir -p ${prodname%/*}/${currentBasename}
        cd ${prodname%/*}
        filename="${prodname##*/}"
        tar xf $filename -C ${currentBasename}
        returnCode=$?
        [ $returnCode -eq 0 ] || return ${ERR_UNPACKING}
        prodname=${prodname%/*}/${currentBasename}
        # in these particular case the product name is not common
        # to the base band names ---> rename all bands
        prodBasename=$(basename ${prodname})
	for bix in 1 2 3 4 5 6 7 9 10 11; 
	do  
       	   currentTif=$(ls "${prodname}"/LC08*_B"${bix}".TIF)
           mv ${currentTif} ${prodname}/${prodBasename}_B${bix}.TIF
           [[ $bix == "1"  ]] && ls ${prodname}/${prodBasename}_B${bix}.TIF > $tifList || ls ${prodname}/${prodBasename}_B${bix}.TIF >> $tifList
        done
    else
        ls "${prodname}"/LS08*_B0[1-7].TIF > $tifList
        ls "${prodname}"/LS08*_B09.TIF >> $tifList
        ls "${prodname}"/LS08*_B1[0,1].TIF >> $tifList
    fi
elif [ ${mission} = "Kompsat-2" ]; then
    # Rename all tif files with the result of get_band_list before to put it in tiflist
    local currentBasename=$(basename ${prodname})
    # source bands list
    sourceBandsList_k2=$(get_band_list "${currentBasename}" "${mission}" )
    # convert band from comma separted values to space separated values
    bandListSsv_k2=$( echo "${sourceBandsList_k2}" | sed 's|,| |g' )
    # convert ssv to array
    declare -a bandListArray_k2=(${bandListSsv_k2})
    # get number of bands
    numBands=${#bandListArray_k2[@]}
    let "numBands-=1"
    local bid=0
    for bid in `seq 0 $numBands`; do
        local product2rename=""
        case "$bid" in
        "0")
            product2rename=$(find "${prodname}" -name 'MSC_*R_1G.tif')
            ;;
        "1")
            product2rename=$(find "${prodname}" -name 'MSC_*G_1G.tif')
            ;;
        "2")
            product2rename=$(find "${prodname}" -name 'MSC_*B_1G.tif')
            ;;
        "3")
            product2rename=$(find "${prodname}" -name 'MSC_*N_1G.tif')
            ;;
        *)
            return "${ERR_PREPROCESS}"
            ;;
        esac
        [ $DEBUG -eq 1 ] && echo call mv ${product2rename} "${prodname}"/${bandListArray_k2[$bid]}.tif 
        mv ${product2rename} "${prodname}"/${bandListArray_k2[$bid]}.tif
        if [ $bid -eq 0  ]; then
            echo "${prodname}"/${bandListArray_k2[$bid]}.tif > $tifList
        else
            echo "${prodname}"/${bandListArray_k2[$bid]}.tif >> $tifList
        fi      
    done
elif [ ${mission} = "Kompsat-3" ]; then
    find "${prodname}" -name 'K3_*_L1G_R*.tif' > $tifList
    find "${prodname}" -name 'K3_*_L1G_G*.tif' >> $tifList
    find "${prodname}" -name 'K3_*_L1G_B*.tif' >> $tifList
    find "${prodname}" -name 'K3_*_L1G_N*.tif' >> $tifList

elif [ ${mission} = "VRSS1" ]; then
    #Check if downloaded product is compressed and extract it (in tar is not automatically extracted, otherwise yes)
    ext="${prodname##*/}"; ext="${ext#*.}"
    ciop-log "INFO" "Product extension is: $ext"
    # assumption is that the product has .tar extension or is already uncompressed
    if  [[ "$ext" == "tar" ]]; then
        ciop-log "INFO" "Extracting $prodname"
        currentBasename=$(basename $prodname)
        currentBasename="${currentBasename%%.*}"
        mkdir -p ${prodname%/*}/${currentBasename}
        cd ${prodname%/*}
        filename="${prodname##*/}"
        tar xf $filename -C ${currentBasename}
        returnCode=$?
        [ $returnCode -eq 0 ] || return ${ERR_UNPACKING}
        prodname=${prodname%/*}/${currentBasename}
    fi
    prodBasename=$(basename ${prodname})     
    vrss1_b1=$(find ${prodname}/ -name '*_1.tif')
    vrss1_name="${vrss1_b1%_1.tif}"
    vrss1_name=$(basename ${vrss1_name})
    # in this case the product name is not common
    # to the base band names ---> rename all bands
    if [ ${prodBasename} != ${vrss1_name} ]; then
        # in this case the product name is not common
        # to the base band names ---> rename all bands
        for bix in 1 2 3 4 ;
        do 
           currentTif=$(find "${prodname}"/ -name *_"${bix}".tif)
           mv ${currentTif} ${prodname}/${prodBasename}_${bix}.tif
           [[ $bix == "1"  ]] && ls ${prodname}/${prodBasename}_${bix}.tif > $tifList || ls ${prodname}/${prodBasename}_${bix}.tif >> $tifList
        done
    else
        find "${prodname}"/ -name '*_1.tif' > $tifList
        find "${prodname}"/ -name '*_2.tif' >> $tifList
        find "${prodname}"/ -name '*_3.tif' >> $tifList
        find "${prodname}"/ -name '*_4.tif' >> $tifList
    fi 
elif [ ${mission} = "RapidEye" ]; then
    prodBasename=$(basename ${prodname})
    tifProd=$(find ${prodname}/ -name ${prodBasename}.tif)
    echo ${tifProd} > $tifList
elif [ ${mission} = "GF2" ]; then
    filename="${prodname##*/}"; ext="${filename#*.}"
    # check extension, uncrompress and get product name
    if [[ "$ext" == "tar" ]]; then
        ciop-log "INFO" "Extracting $prodname"
        currentBasename=$(basename $prodname)
        currentBasename="${currentBasename%%.*}"
        mkdir -p ${prodname%/*}/${currentBasename}
        cd ${prodname%/*}
        tar xf $filename -C ${currentBasename}
        returnCode=$?
        [ $returnCode -eq 0 ] || return ${ERR_UNPACKING}
        prodname=${prodname%/*}/${currentBasename}
        prodBasename=$(basename ${prodname})
        # get multispectral tif product
        mss_product=$(ls "${prodname}"/*MSS2.tiff)
        echo ${mss_product} > $tifList
    else
        return ${ERR_GETDATA}
    fi
elif [ ${mission} = "Kanopus-V" ] || [ ${mission} = "Resurs-P" ]; then
    prodBasename=$(basename ${prodname})
    tifProd=$(find ${prodname} -name *.tiff)
    # check if there are more than one tif (case when also the panchromatic product is present)
    tifProdArr=($tifProd)
    tifProdArr_num=${#tifProdArr[@]}
    if [ $tifProdArr_num -eq 0 ]; then
        ciop-log "ERROR" "No tif product found"
        return ${ERR_PREPROCESS}
    elif [ $tifProdArr_num -eq 1 ]; then
        echo ${tifProd} > $tifList
    # get multispectral product as default
    else
        let "tifProdArr_num-=1"
        for idTmp in `seq 0 $tifProdArr_num`;
        do
            num_bands=$(get_bands_num_tif "${tifProdArr[$idTmp]}")
            retCode=$?
            [ $retCode -eq 0 ] || return ${retCode}
            if [ $num_bands -gt 1 ]; then
	        echo ${tifProdArr[$idTmp]} > $tifList
                break
            fi   
        done
    fi
else
    return ${ERR_PREPROCESS}
fi
[ $DEBUG -eq 1 ] && echo tifList $tifList
[ $DEBUG -eq 1 ] && echo tifList content $(cat $tifList)
inputProdBasenameNoExt=$(basename ${prodname})
# customized targetBandsNamesListTXT for RapidEye, GF2, Kanopus-V and Resurs-P (due to 1 Tiff with all bands already embedded)
if [ ${mission} = "RapidEye" ] || [ ${mission} = "GF2" ] || [ ${mission} = "Kanopus-V" ] || [ ${mission} = "Resurs-P" ]; then
   filesListCSV=$(cat "${tifList}")
   # source bands list for
   tempBandsList=$(get_band_list "${inputProdBasenameNoExt}" "${mission}" "${prodname}" )
   # convert file list from comma separted values to space separated values
   tempBandsListSsv=$( echo "${tempBandsList}" | sed 's|,| |g' )
   # convert ssv to array
   declare -a tempBandsListArray=(${tempBandsListSsv})
   tempBandsListArray_num=${#tempBandsListArray[@]}
   # loop on band names to fill targetBandsNamesListTXT
   let "tempBandsListArray_num-=1"
   for indexTemp in `seq 0 $tempBandsListArray_num`;
       do
       if [ $indexTemp -eq 0  ] ; then
           echo ${tempBandsListArray[${indexTemp}]} > ${targetBandsNamesListTXT}
       else
           echo ${tempBandsListArray[${indexTemp}]} >> ${targetBandsNamesListTXT}
       fi
   done
# all the other cases loop on the tif files for targetBandsNamesListTXT filling
else
    for tif in $(cat "${tifList}"); do
        basenameNoExt=$(basename "$tif")
        basenameNoExt="${basenameNoExt%.*}"
        if [ $index -eq 0  ] ; then
            filesListCSV=$tif
            echo ${basenameNoExt} > ${targetBandsNamesListTXT}
        else
            filesListCSV=$filesListCSV,$tif
            echo ${basenameNoExt} >> ${targetBandsNamesListTXT}
        fi
        let "index=index+1"
    done
fi
[ $DEBUG -eq 1 ] && echo filesListCSV $filesListCSV
# number of product equal to the last index value due to how the loop works
numProd=$index
# report activity in the log
ciop-log "INFO" "Products stacking"
# output product name
outProdStack=${TMPDIR}/stack_product
# customized processing for kompsat-2 and VRSS1 because snap fails
if [ ${mission} = "Kompsat-2" ] || [ ${mission} = "VRSS1" ] ; then
    # convert file list from comma separted values to space separated values
    filesListSsv=$( echo "${filesListCSV}" | sed 's|,| |g' )
    # convert ssv to array
    declare -a filesListArray=(${filesListSsv})
    # gdal_merge to create stack product
    gdal_merge.py -separate -n 0 "${filesListArray[0]}" "${filesListArray[1]}" "${filesListArray[2]}" "${filesListArray[3]}"  -o ${outProdStack}.tif
    [ $? -eq 0 ] || return ${ERR_GDAL}
    # pconvert to convert GeoTIFF to BEAM-DIMAP
    pconvert -f dim -o ${TMPDIR} ${outProdStack}.tif
    [ $? -eq 0 ] || return ${ERR_PCONVERT}
    # remove intermediate GeoTIFF K2 stack
    rm ${outProdStack}.tif   
# customized processing for RapidEye, GF2, Kanopus-V and Resurs-P because there is no need for merging (1 Tiff with all bands already embedded)
elif [ ${mission} = "RapidEye" ] || [ ${mission} = "GF2" ] || [ ${mission} = "Kanopus-V" ] || [ ${mission} = "Resurs-P" ] ; then
    file2convert=$(echo ${filesListCSV})
    cp ${file2convert} ${outProdStack}.tif
    # pconvert to convert GeoTIFF to BEAM-DIMAP
    pconvert -f dim -o ${TMPDIR} ${outProdStack}.tif 
    [ $? -eq 0 ] || return ${ERR_PCONVERT}
    # remove intermediate GeoTIFF K2 stack
    rm ${outProdStack}.tif
else
    # prepare the SNAP request
    SNAP_REQUEST=$( create_snap_request_stack "${filesListCSV}" "${outProdStack}" "${numProd}" )
    [ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
    [ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
    # report activity in the log
    ciop-log "INFO" "Invoking SNAP-gpt request file for products stacking"
    # invoke the ESA SNAP toolbox
    gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
    # check the exit code
    [ $? -eq 0 ] || return $ERR_SNAP
fi

# get band names
currentBandsList=$( xmlstarlet sel -t -v "/Dimap_Document/Image_Interpretation/Spectral_Band_Info/BAND_NAME" ${outProdStack}.dim )
currentBandsList=(${currentBandsList})
currentBandsList_num=${#currentBandsList[@]}
currentBandsListTXT=${TMPDIR}/currentBandsList.txt
# loop on band names to fill band list
let "currentBandsList_num-=1"
for index in `seq 0 $currentBandsList_num`;
do
    if [ $index -eq 0  ] ; then
        echo ${currentBandsList[${index}]} > ${currentBandsListTXT}
    else
        echo  ${currentBandsList[${index}]} >> ${currentBandsListTXT}
    fi
done

# build request file for rename all the bands contained into the stack product
# report activity in the log
outProdRename=${TMPDIR}/stack_renamed_bands
ciop-log "INFO" "Preparing SNAP request file for bands renaming"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rename_all_bands "${outProdStack}.dim" "${currentBandsListTXT}" "${targetBandsNamesListTXT}" "${outProdRename}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file bands renaming"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
rm -rf ${outProdStack}.d*

# use the greter pixel spacing as target spacing (in order to downsample if needed, upsampling always avoided)
local target_spacing=$( get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster} )
# check for resampling operator: to be used only if the resolution is differenet from the current product one
local performResample=""
if (( $(bc <<< "$target_spacing != $pixelSpacing") )) ; then
    performResample="true"
else
    performResample="false"
fi
outProdBasename=${inputProdBasenameNoExt}_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for optical data pre processing"
# source bands list for
sourceBandsList=$(get_band_list "${inputProdBasenameNoExt}" "${mission}" )
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rsmpl_rprj_sbs "${outProdRename}.dim" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"

# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for optical data pre processing"

# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
rm log.txt
rm -rf ${outProdRename}.d* ${tifList} ${targetBandsNamesListTXT}
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    # no error case
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        # error due to void intersection between user AOI and data
        return $ERR_AOI
    else
        # generic snap-gpt execution error
        return $ERR_SNAP
    fi
fi

}


# Pre processing function for Kompsat-5
function pre_processing_k5() {
# function call pre_processing_k5 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 5 ] && return ${ERR_PREPROCESS}

local prodname=$1
local pixelSpacing=$2
local pixelSpacingMaster=$3
local performCropping=$4
local subsettingBoxWKT=$5
local index=0
prodBasename=$(basename ${prodname})
local imgFile=""
imgFile=$(find ${prodname}/ -name 'K5_*_L1D.tif')
# remove metadata from tif to avoid that SNAP-gpt uses the K5 reader (that doesn't work) while converting into DIM
gdal_edit.py -unsetmd ${imgFile}
[ $? -eq 0 ] || return ${ERR_GDAL}
# rename data to avoid that SNAP-gpt uses the K5 reader (that doesn't work) while converting into DIM
file2convert=${TMPDIR}/product2convert.tif
# get source crs info
s_crs=$(gdalsrsinfo -o wkt ${imgFile} | sed -n -e 's|^.*"EPSG","\(.*\)"]]|\1|p')
# reproject data for correct CRS handling by following snap operators
gdalwarp -ot UInt16 -srcnodata 0 -dstnodata 0 -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -s_srs EPSG:${s_crs} -t_srs EPSG:4326 ${imgFile} ${file2convert}
# convert tif to beam dimap format
ciop-log "INFO" "Invoking SNAP-pconvert on the generated request file for tif to dim conversion"
pconvert -f dim -o ${TMPDIR} ${file2convert}
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
# remove temp file
rm -r -f ${file2convert}
# get translated product name
imgFileDIM=${TMPDIR}/product2convert.dim
# define output name of DIM product with K5 file converted into dB
imgFileDIM_dB=${TMPDIR}/${prodBasename}_dB.dim
ciop-log "INFO" "Preparing SNAP request file for dB scaling"
SNAP_REQUEST=$( create_snap_request_linear_to_dB "${imgFileDIM}" "${imgFileDIM_dB}" )
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for dB scaling"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
# remove temp file product in beam dimap
rm -rf "${imgFileDIM%.dim}.d*"
# get bands name
currentBandsList=$( xmlstarlet sel -t -v "/Dimap_Document/Image_Interpretation/Spectral_Band_Info/BAND_NAME" ${imgFileDIM_dB} )
currentBandsList=(${currentBandsList})
currentBandsList_num=${#currentBandsList[@]}
currentBandsListTXT=${TMPDIR}/currentBandsList.txt
# loop on band names to fill band list
let "currentBandsList_num-=1"
for index in `seq 0 $currentBandsList_num`;
do
    if [ $index -eq 0  ] ; then
        echo ${currentBandsList[${index}]} > ${currentBandsListTXT}
    else
        echo  ${currentBandsList[${index}]} >> ${currentBandsListTXT}
    fi
done
# loop over known product bands to fill target bands list
targetBandsNamesListTXT=${TMPDIR}/targetBandsNamesList.txt
# source bands list for Pleiades
sourceBandsList=$(get_band_list "${prodBasename}" "Kompsat-5" )
# convert band from comma separted values to space separated values
bandListSsv=$( echo "${sourceBandsList}" | sed 's|,| |g' )
# convert ssv to array
declare -a bandListArray=(${bandListSsv})
# get number of bands
numBands=${#bandListArray[@]}
local bid=0
let "numBands-=1"
for bid in `seq 0 $numBands`; do
    if [ $bid -eq 0  ] ; then
        echo ${bandListArray[$bid]} > ${targetBandsNamesListTXT}
    else
        echo ${bandListArray[$bid]} >> ${targetBandsNamesListTXT}
    fi
done
# build request file for rename all the bands contained into the product
# report activity in the log
outProdRename=${TMPDIR}/output_renamed_bands
ciop-log "INFO" "Preparing SNAP request file for bands renaming"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rename_all_bands "${imgFileDIM_dB}" "${currentBandsListTXT}" "${targetBandsNamesListTXT}" "${outProdRename}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file bands renaming"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
# remove temp calibrated file product in beam dimap
rm -rf "${imgFileDIM_dB%.dim}.d*"

# use the greter pixel spacing as target spacing (in order to downsample if needed, upsampling always avoided)
local target_spacing=$( get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster} )
# force performResample to false due to SNAP bug with this particular mission data
# check for resampling operator: to be used only if the resolution is differenet from the current product one
local performResample="false"
#if (( $(bc <<< "$target_spacing != $pixelSpacing") )) ; then
#    performResample="true"
#else
#    performResample="false"
#fi
outProdBasename=${prodBasename}_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for data pre processing"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rsmpl_rprj_sbs "${outProdRename}.dim" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for data pre processing"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
rm -rf ${outProdRename}.d* ${targetBandsNamesListTXT}
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    # no error case
    rm log.txt
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        # error due to void intersection between user AOI and data
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        return $ERR_AOI
    else
        # generic snap-gpt execution error
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        return $ERR_SNAP
    fi
fi

}


# Pre processing function for Terrasar-X
function pre_processing_tsx() {
# function call pre_processing_tsx "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 5 ] && return ${ERR_PREPROCESS}

local prodname=$1
local pixelSpacing=$2
local pixelSpacingMaster=$3
local performCropping=$4
local subsettingBoxWKT=$5
# find IMAGEDAT dir where tsx product is located
IMAGEDATA=""
if [[ -d "${prodname}" ]]; then
    IMAGEDATA=$(find ${prodname} -name 'IMAGEDATA')
    if [[ -z "$IMAGEDATA" ]]; then 
        ciop-log "ERROR" "Failed to get IMAGEDATA dir"
	return ${ERR_PREPROCESS}
    fi
elif [[ "${prodname##*.}" == "tar" ]]; then
    mkdir tsx_temp 
    tar xf ${prodname} -C tsx_temp/
    returnCode=$?
    [ $returnCode -eq 0 ] || return ${ERR_PREPROCESS}
    IMAGEDATA=$(find $PWD/tsx_temp/ -name 'IMAGEDATA')
    if [[ -z "$IMAGEDATA" ]]; then
        ciop-log "ERROR" "Failed to get IMAGEDATA dir"
        return ${ERR_PREPROCESS}
    fi
fi
prodBasename=$(basename ${prodname})
prodBasename="${prodBasename%%.*}"
local imgFile=""
imgFile=$(find ${IMAGEDATA}/ -name '*.tif')
file2convert=${TMPDIR}/product2convert.tif
# reproject data for correct CRS handling by following snap operators
gdalwarp -ot UInt16 -srcnodata 0 -dstnodata 0 -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -t_srs EPSG:4326 ${imgFile} ${file2convert}
# convert tif to beam dimap format
ciop-log "INFO" "Invoking SNAP-pconvert on the generated request file for tif to dim conversion"
pconvert -f dim -o ${TMPDIR} ${file2convert}
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
#remove temp folder
rm -r -f tsx_temp ${file2convert}
# get translated product name
imgFileDIM=${TMPDIR}/product2convert.dim
# get bands name
currentBandsList=$( xmlstarlet sel -t -v "/Dimap_Document/Image_Interpretation/Spectral_Band_Info/BAND_NAME" ${imgFileDIM} )
currentBandsList=(${currentBandsList})
currentBandsList_num=${#currentBandsList[@]}
currentBandsListTXT=${TMPDIR}/currentBandsList.txt
local index=0
# loop on band names to fill band list
let "currentBandsList_num-=1"
for index in `seq 0 $currentBandsList_num`;
do
    if [ $index -eq 0  ] ; then
        echo ${currentBandsList[${index}]} > ${currentBandsListTXT}
    else
        echo  ${currentBandsList[${index}]} >> ${currentBandsListTXT}
    fi
done
# loop over known product bands to fill target bands list
targetBandsNamesListTXT=${TMPDIR}/targetBandsNamesList.txt
# source bands list for Pleiades
sourceBandsList=$(get_band_list "${prodBasename}" "TerraSAR-X" "${prodname}")
# convert band from comma separted values to space separated values
bandListSsv=$( echo "${sourceBandsList}" | sed 's|,| |g' )
# convert ssv to array
declare -a bandListArray=(${bandListSsv})
# get number of bands
numBands=${#bandListArray[@]}
local bid=0
let "numBands-=1"
for bid in `seq 0 $numBands`; do
    if [ $bid -eq 0  ] ; then
        echo ${bandListArray[$bid]} > ${targetBandsNamesListTXT}
    else
        echo ${bandListArray[$bid]} >> ${targetBandsNamesListTXT}
    fi
done
# build request file for rename all the bands contained into the product
# report activity in the log
outProdRename=${TMPDIR}/output_renamed_bands
ciop-log "INFO" "Preparing SNAP request file for bands renaming"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rename_all_bands "${imgFileDIM}" "${currentBandsListTXT}" "${targetBandsNamesListTXT}" "${outProdRename}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file bands renaming"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
# remove temp calibrated file product in beam dimap
rm -rf "${imgFileDIM%.dim}.d*"

# use the greter pixel spacing as target spacing (in order to downsample if needed, upsampling always avoided)
local target_spacing=$( get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster} )
# check for resampling operator: to be used only if the resolution is differenet from the current product one
local performResample=""
if (( $(bc <<< "$target_spacing != $pixelSpacing") )) ; then
    performResample="true"
else
    performResample="false"
fi
outProdBasename=${prodBasename}_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for data pre processing"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rsmpl_rprj_sbs "${outProdRename}.dim" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for data pre processing"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
rm -rf ${outProdRename}.d* ${targetBandsNamesListTXT}
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    # no error case
    rm log.txt
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        # error due to void intersection between user AOI and data
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        return $ERR_AOI
    else
        # generic snap-gpt execution error
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        return $ERR_SNAP
    fi
fi

}


# Pre processing function for alos2
function pre_processing_alos2() {
# function call pre_processing_alos2 "${prodname}" "${pixelSpacing}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"

inputNum=$#
[ "$inputNum" -ne 5 ] && return ${ERR_PREPROCESS}

local prodname=$1
local pixelSpacing=$2
local pixelSpacingMaster=$3
local performCropping=$4
local subsettingBoxWKT=$5
local index=0

#check on alos product format 
if [[ -d "${prodname}" ]]; then
    ALOS_ZIP=$(ls ${prodname} | egrep '^.*ALOS2.*.zip$')
fi
local alos2unzip=""
local prodBasename=""
# if doesn't contain a zip it should be already uncompressed
if [[ -z "$ALOS_ZIP" ]] ; then
    alos2unzip=${prodname}
    prodBasename=$(basename ${prodname})
# else uncompress zipped archive
else
    # get basename from zip filename
    ALOS_ZIP_basename=$(basename ${ALOS_ZIP})
    prodBasename="${ALOS_ZIP_basename%%.*}"
    alos2unzip=${TMPDIR}/alos2unzip
    mkdir ${alos2unzip}
    unzip $ALOS_ZIP -d ${alos2unzip}
fi

# source bands list
sourceBandsList_alos2=$(get_band_list "${prodBasename}" "${mission}" "${prodname}")
# convert band from comma separted values to space separated values
bandListSsv_alos2=$( echo "${sourceBandsList_alos2}" | sed 's|,| |g' )
# convert ssv to array
declare -a bandListArray_alos2=(${bandListSsv_alos2})
# get number of bands
numBands=${#bandListArray_alos2[@]}
let "numBandsLoop=numBands-1"
local bid=0
# get tif list in a space separted value manner
local tifListSsv=""
for bid in `seq 0 $numBandsLoop`; do
    currentTifName=$( find ${alos2unzip}/ -name "IMG-""${bandListArray_alos2[$bid]}""*.tif")
    case "$bid" in
	"0")
            tifListSsv=${currentTifName}
            ;;
        *)
            tifListSsv="${tifListSsv} ${currentTifName}"
            ;;
    esac
done
tifListArray=(${tifListSsv})
tifListArray_num=${#tifListArray[@]}
let "array_num=tifListArray_num-1"
# loop to perform linear2dB conversion and stacking
lin2dbFolder=${TMPDIR}/lin2db
mkdir ${lin2dbFolder}
tifListDbSsv=""
for index in `seq 0 $array_num`;
do
    currentTif=${tifListArray[$index]}
    currentTifBasename=$(basename $currentTif)
    currentTif_dB=${lin2dbFolder}/${currentTifBasename}
    # reprojection becasue alos 2 crs is not well recognized by snap
    ciop-log "INFO" "Reprojection"   
    gdalwarp -ot UInt16 -srcnodata 0 -dstnodata 0 -co "TILED=YES" -co "BLOCKXSIZE=512" -co "BLOCKYSIZE=512" -t_srs EPSG:4326 ${currentTif} temp-outputfile.tif
    # dB scaling
    ciop-log "INFO" "Preparing SNAP request file for dB scaling"
    [ $DEBUG -eq 1 ] && echo currentTif $currentTif
    [ $DEBUG -eq 1 ] && echo currentTif_dB $currentTif_dB 
    SNAP_REQUEST=$( create_snap_request_linear_to_dB "temp-outputfile.tif" "${currentTif_dB}" )
    [ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
    [ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
    # report activity in the log
    ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
    # report activity in the log
    ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for dB scaling"
    # invoke the ESA SNAP toolbox
    gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
    # check the exit code
    [ $? -eq 0 ] || return $ERR_SNAP
    # remove temp file 
    rm temp-outputfile.tif
    case "$index" in
        "0")
            tifListDbSsv=${currentTif_dB}
            ;;
        *)
            tifListDbSsv="${tifListDbSsv} ${currentTif_dB}"
            ;;
    esac

done
[ $DEBUG -eq 1 ] && echo tifListDbSsv $tifListDbSsv
# tif file with all polarizations stacked to be converted in dim
file2convert=${TMPDIR}/product2convert.tif
ciop-log "INFO" "Invoking gdal_merge to stack all polarization channels in a single tif"
# gdal_merge to create stack product
gdal_merge.py -separate -n 0 ${tifListDbSsv} -o ${file2convert}
[ $? -eq 0 ] || return ${ERR_GDAL}
# convert tif to beam dimap format
ciop-log "INFO" "Invoking SNAP-pconvert on the generated request file for tif to dim conversion"
pconvert -f dim -o ${TMPDIR} ${file2convert}
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
# remove temp file 
rm -r -f ${file2convert}
# get filename of image dB scaled and converted in DIM
imgFileDIM_dB=${TMPDIR}/product2convert.dim
# remove temp files
rm -r -f $lin2dbFolder
# get bands name
currentBandsList=$( xmlstarlet sel -t -v "/Dimap_Document/Image_Interpretation/Spectral_Band_Info/BAND_NAME" ${imgFileDIM_dB} )
currentBandsList=(${currentBandsList})
currentBandsList_num=${#currentBandsList[@]}
currentBandsListTXT=${TMPDIR}/currentBandsList.txt
# loop on band names to fill band list
let "currentBandsList_num-=1"
for index in `seq 0 $currentBandsList_num`;
do
    if [ $index -eq 0  ] ; then
        echo ${currentBandsList[${index}]} > ${currentBandsListTXT}
    else
        echo  ${currentBandsList[${index}]} >> ${currentBandsListTXT}
    fi
done
# loop over known product bands to fill target bands list
targetBandsNamesListTXT=${TMPDIR}/targetBandsNamesList.txt
# source bands list for Alos-2
sourceBandsList=${sourceBandsList_alos2}
# convert band from comma separted values to space separated values
bandListSsv=$( echo "${sourceBandsList}" | sed 's|,| |g' )
# convert ssv to array
declare -a bandListArray=(${bandListSsv})
# get number of bands
numBands=${#bandListArray[@]}
local bid=0
let "numBands-=1"
for bid in `seq 0 $numBands`; do
    if [ $bid -eq 0  ] ; then
        echo ${bandListArray[$bid]} > ${targetBandsNamesListTXT}
    else
        echo ${bandListArray[$bid]} >> ${targetBandsNamesListTXT}
    fi
done
# build request file for rename all the bands contained into the product
# report activity in the log
outProdRename=${TMPDIR}/output_renamed_bands
ciop-log "INFO" "Preparing SNAP request file for bands renaming"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rename_all_bands "${imgFileDIM_dB}" "${currentBandsListTXT}" "${targetBandsNamesListTXT}" "${outProdRename}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file bands renaming"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
# remove temp calibrated file product in beam dimap
rm -rf "${imgFileDIM_dB%.dim}.d*"

# use the greter pixel spacing as target spacing (in order to downsample if needed, upsampling always avoided)
local target_spacing=$( get_greater_pixel_spacing ${pixelSpacing} ${pixelSpacingMaster} )

# fixed value of performResample variable due to SNAP error in resampling Alos data
performResample="false"

outProdBasename=${prodBasename}_pre_proc
outProd=${OUTPUTDIR_PRE_PROC}/${outProdBasename}

# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for data pre processing"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_rsmpl_rprj_sbs "${outProdRename}.dim" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for data pre processing"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" 2> log.txt
returncode=$?
test_txt=$(cat log.txt | grep "No intersection")
rm -rf ${outProdRename}.d* ${targetBandsNamesListTXT}
# catch proper error if any
if [ $returncode -eq 0 ] ; then
    # no error case
    rm log.txt
    return 0
else
    if [[ "${test_txt}" != "" ]]; then
        # error due to void intersection between user AOI and data
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        return $ERR_AOI
    else
        # generic snap-gpt execution error
        [ $DEBUG -eq 1 ] && cat log.txt
        rm log.txt
        return $ERR_SNAP
    fi
fi

}



function create_snap_request_linear_to_dB(){
# function call: create_snap_request_linear_to_dB "${inputfile}" "${outputfile}"

# function which creates the actual request from
# a template and returns the path to the request

# get number of inputs
inputNum=$#
# check on number of inputs
if [ "$inputNum" -ne "2" ] ; then
    return ${SNAP_REQUEST_ERROR}
fi

local inputfile=$1
local outputfile=$2
local filename="${outputfile##*/}" 
local ext="${filename##*.}"
local format=""
if [[ "$ext" == "dim" ]]; then
    format="BEAM-DIMAP" 
elif [[ "$ext" == "tif" ]]; then
    format="GeoTIFF-BigTIFF"
else
    return ${SNAP_REQUEST_ERROR}    
fi


#sets the output filename
snap_request_filename="${TMPDIR}/$( uuidgen ).xml"

cat << EOF > ${snap_request_filename}
<graph id="Graph">
  <version>1.0</version>
  <node id="Read">
    <operator>Read</operator>
    <sources/>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${inputfile}</file>
    </parameters>
  </node>
  <node id="BandMaths">
    <operator>BandMaths</operator>
    <sources>
      <sourceProduct refid="Read"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <targetBands>
        <targetBand>
          <name>band_1</name>
          <type>uint8</type>
          <expression>if fneq(band_1,0) then max(20*log10(band_1),1) else 0</expression>
          <description/>
          <unit/>
          <noDataValue>0.0</noDataValue>
        </targetBand>
      </targetBands>
      <variables/>
    </parameters>
  </node>
  <node id="Write">
    <operator>Write</operator>
    <sources>
      <sourceProduct refid="BandMaths"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outputfile}</file>
      <formatName>${format}</formatName>
    </parameters>
  </node>
  <applicationData id="Presentation">
    <Description/>
    <node id="Read">
            <displayPosition x="37.0" y="134.0"/>
    </node>
    <node id="BandMaths">
      <displayPosition x="247.0" y="132.0"/>
    </node>
    <node id="Write">
            <displayPosition x="455.0" y="135.0"/>
    </node>
  </applicationData>
</graph>
EOF

    [ $? -eq 0 ] && {
        echo "${snap_request_filename}"
        return 0
    } || return ${SNAP_REQUEST_ERROR}

}


function create_snap_request_stack(){
# function call: create_snap_request_stack "${inputfiles_list}" "${outProdDIM}" "${numProd}"

    # function which creates the actual request from
    # a template and returns the path to the request

    # get number of inputs
    inputNum=$#
    # check on number of inputs
    if [ "$inputNum" -ne "3" ] ; then
        return ${SNAP_REQUEST_ERROR}
    fi

    local inputfiles_list=$1
    local outProdDIM=$2
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
      <fileList>${inputfiles_list}</fileList>
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
      <resamplingType>NONE</resamplingType>
      <extent>Master</extent>
      <initialOffsetMethod>Product Geolocation</initialOffsetMethod>
    </parameters>
  </node>
  <node id="Write">
    <operator>Write</operator>
    <sources>
      <sourceProduct refid="CreateStack"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outProdDIM}.dim</file>
      <formatName>BEAM-DIMAP</formatName>
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


# function for renaming all the bands
function create_snap_request_rename_all_bands(){
# function call create_snap_request_rename_all_bands "${inputProdDIM}" "${currentBandsListTXT}" "${targetBandsNamesListTXT}" "${outProdRename}"

# function which creates the actual request from
# a template and returns the path to the request

# get number of inputs
inputNum=$#
# check on number of inputs
if [ "$inputNum" -ne "4" ] ; then
    return ${SNAP_REQUEST_ERROR}
fi

local inputProdDIM=$1
local currentBandsListTXT=$2
local targetBandsNamesListTXT=$3
local outProdRename=$4

# loop to fill xml operator to rename bands and merge them
local bandsSetRename=${TMPDIR}/bandSetRename.txt
local bandMerge=${TMPDIR}/bandSetMerge.txt
cat << EOF > ${bandMerge}
  <node id="BandMerge">
    <operator>BandMerge</operator>
    <sources>
EOF

declare -a currentBandsList
declare -a targetBandsNamesList
for currBand in $( cat ${currentBandsListTXT}) ; do
    currentBandsList+=("${currBand}")
done
for targetBand in $( cat ${targetBandsNamesListTXT}) ; do
    targetBandsNamesList+=("${targetBand}")
done
currentBandsList_num=${#currentBandsList[@]}
targetBandsNamesList_num=${#targetBandsNamesList[@]}

# loop on band names to fill band list
let "currentBandsList_num-=1"
for index in `seq 0 $currentBandsList_num`;
do
    bandSetRenameTmp=${TMPDIR}/bandSetRenameTmp.txt
    cat << EOF > ${bandSetRenameTmp}
    <node id="BandMaths($index)">
    <operator>BandMaths</operator>
    <sources>
      <sourceProduct refid="Read"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <targetBands>
        <targetBand>
          <name>${targetBandsNamesList[${index}]}</name>
          <type>float32</type>
          <expression>${currentBandsList[${index}]}</expression>
          <description/>
          <unit/>
          <noDataValue>0.0</noDataValue>
        </targetBand>
      </targetBands>
      <variables/>
    </parameters>
  </node>
EOF
    if [ $index -eq 0  ] ; then
        cat ${bandSetRenameTmp} > ${bandsSetRename}
    else
        cat ${bandSetRenameTmp} >> ${bandsSetRename}
    fi
    rm ${bandSetRenameTmp}

    bandSetMergeTmp=${TMPDIR}/bandSetMergeTmp.txt
    num=""
    [ $index -ne 0 ] && num=.$index
        cat << EOF > ${bandSetMergeTmp}
<sourceProduct$num refid="BandMaths($index)"/>
EOF
    cat ${bandSetMergeTmp} >> ${bandMerge}
    rm ${bandSetMergeTmp}
done

bandSetMergeTmp=${TMPDIR}/bandSetMergeTmp.txt
cat << EOF > ${bandSetMergeTmp}
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <geographicError>1.0E-5</geographicError>
    </parameters>
  </node>
EOF

cat ${bandSetMergeTmp} >> ${bandMerge}
rm ${bandSetMergeTmp}

#sets the output filename
    snap_request_filename="${TMPDIR}/$( uuidgen ).xml"

cat << EOF > ${snap_request_filename}
<graph id="Graph">
  <version>1.0</version>
  <node id="Read">
    <operator>Read</operator>
    <sources/>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${inputProdDIM}</file>
    </parameters>
  </node>
EOF

cat ${bandsSetRename} >> ${snap_request_filename}
cat ${bandMerge} >> ${snap_request_filename}

tmpWrite=${TMPDIR}/writeTmp.txt
cat << EOF > ${tmpWrite}
  <node id="Write">
    <operator>Write</operator>
    <sources>
      <sourceProduct refid="BandMerge"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outProdRename}.dim</file>
      <formatName>BEAM-DIMAP</formatName>
    </parameters>
  </node>
  <applicationData id="Presentation">
    <Description/>
    <node id="Write">
            <displayPosition x="455.0" y="135.0"/>
    </node>
    <node id="BandMerge">
      <displayPosition x="240.0" y="132.0"/>
    </node>
    <node id="Read">
      <displayPosition x="39.0" y="131.0"/>
    </node>
  </applicationData>
</graph>
EOF

cat ${tmpWrite} >> ${snap_request_filename}
rm ${tmpWrite}
echo "${snap_request_filename}"
return 0

}


function create_snap_request_rsmpl_rprj_sbs() {

# function call create_snap_request_rsmpl_rprj_sbs "${prodname}" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}"

# function which creates the actual request from
# a template and returns the path to the request

inputNum=$#
[ "$inputNum" -ne 7 ] && return ${ERR_PREPROCESS}

local prodname=$1
local performResample=$2
local target_spacing=$3
local performCropping=$4
local subsettingBoxWKT=$5
local sourceBandsList=$6
local outprod=$7
# perform ceiling on target_spacing (resampling needs integer spacing)
local pixelSpacing_floor=$(echo "scale=0; $target_spacing/1" | bc )
(( $(bc <<< "$pixelSpacing_floor == $target_spacing") )) || let "target_spacing=pixelSpacing_floor+1" 

local commentRsmpBegin=""
local commentRsmpEnd=""
local commentReadSrcBegin=""
local commentReadSrcEnd=""
local commentSbsBegin=""
local commentSbsEnd=""
local commentMlBegin=""
local commentMlEnd=""
local commentProjSrcBegin=""
local commentProjSrcEnd=""

local beginCommentXML="<!--"
local endCommentXML="-->"

# check for resampling operator usage
if [ "${performResample}" = false ] ; then
    commentRsmpBegin="${beginCommentXML}"
    commentRsmpEnd="${endCommentXML}"
else
    commentReadSrcBegin="${beginCommentXML}"
    commentReadSrcEnd="${endCommentXML}"
fi
# check for subset operator usage
if [ "${performCropping}" = false ] ; then
    commentSbsBegin="${beginCommentXML}"
    commentSbsEnd="${endCommentXML}"
else
    commentProjSrcBegin="${beginCommentXML}"
    commentProjSrcEnd="${endCommentXML}"
fi

#sets the output filename
snap_request_filename="${TMPDIR}/$( uuidgen ).xml"

   cat << EOF > ${snap_request_filename}
<graph id="Graph">
  <version>1.0</version>
  <node id="Read">
    <operator>Read</operator>
    <sources/>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${prodname}</file>
    </parameters>
  </node>
${commentRsmpBegin}  <node id="Resample">
    <operator>Resample</operator>
    <sources>
      <sourceProduct refid="Read"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <referenceBand/>
      <targetWidth/>
      <targetHeight/>
      <targetResolution>${target_spacing}</targetResolution>
      <upsampling>Nearest</upsampling>
      <downsampling>First</downsampling>
      <flagDownsampling>First</flagDownsampling>
      <resampleOnPyramidLevels>false</resampleOnPyramidLevels>
    </parameters>
  </node> ${commentRsmpEnd}
  <node id="Reproject">
    <operator>Reproject</operator>
    <sources>
${commentRsmpBegin}      <sourceProduct refid="Resample"/> ${commentRsmpEnd}
${commentReadSrcBegin}   <sourceProduct refid="Read"/> ${commentReadSrcEnd}
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <wktFile/>
      <crs>GEOGCS[&quot;WGS84(DD)&quot;, &#xd;
  DATUM[&quot;WGS84&quot;, &#xd;
    SPHEROID[&quot;WGS84&quot;, 6378137.0, 298.257223563]], &#xd;
  PRIMEM[&quot;Greenwich&quot;, 0.0], &#xd;
  UNIT[&quot;degree&quot;, 0.017453292519943295], &#xd;
  AXIS[&quot;Geodetic longitude&quot;, EAST], &#xd;
  AXIS[&quot;Geodetic latitude&quot;, NORTH]]</crs>
      <resampling>Nearest</resampling>
      <referencePixelX/>
      <referencePixelY/>
      <easting/>
      <northing/>
      <orientation/>
      <pixelSizeX/>
      <pixelSizeY/>
      <width/>
      <height/>
      <tileSizeX/>
      <tileSizeY/>
      <orthorectify>false</orthorectify>
      <elevationModelName/>
      <noDataValue>NaN</noDataValue>
      <includeTiePointGrids>true</includeTiePointGrids>
      <addDeltaBands>false</addDeltaBands>
    </parameters>
  </node>
${commentSbsBegin}  <node id="Subset">
    <operator>Subset</operator>
    <sources>
      <sourceProduct refid="Reproject"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <region/>
      <geoRegion>${subsettingBoxWKT}</geoRegion>
      <subSamplingX>1</subSamplingX>
      <subSamplingY>1</subSamplingY>
      <fullSwath>false</fullSwath>
      <tiePointGridNames/>
      <copyMetadata>true</copyMetadata>
    </parameters>
  </node> ${commentSbsEnd}
  <node id="BandSelect">
    <operator>BandSelect</operator>
    <sources>
      ${commentSbsBegin} <sourceProduct refid="Subset"/> ${commentSbsEnd}
      ${commentProjSrcBegin} <sourceProduct refid="Reproject"/> ${commentProjSrcEnd}
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <selectedPolarisations/>
      <sourceBands>${sourceBandsList}</sourceBands>
      <bandNamePattern/>
    </parameters>
  </node>
  <node id="Write">
    <operator>Write</operator>
    <sources>
       <sourceProduct refid="BandSelect"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outprod}.dim</file>
      <formatName>BEAM-DIMAP</formatName>
    </parameters>
  </node>
  <applicationData id="Presentation">
    <Description/>
    <node id="Write">
            <displayPosition x="455.0" y="135.0"/>
    </node>
    <node id="BandSelect">
      <displayPosition x="400.0" y="136.0"/>
    </node>
    <node id="Subset">
      <displayPosition x="327.0" y="136.0"/>
    </node>
    <node id="Reproject">
      <displayPosition x="231.0" y="137.0"/>
    </node>
    <node id="Resample">
      <displayPosition x="140.0" y="133.0"/>
    </node>
    <node id="Read">
            <displayPosition x="37.0" y="134.0"/>
    </node>
  </applicationData>
</graph>
EOF

    [ $? -eq 0 ] && {
        echo "${snap_request_filename}"
        return 0
    } || return ${SNAP_REQUEST_ERROR}
}

function create_snap_request_rsmpl_rprj_sbs_s3() {

# function call create_snap_request_rsmpl_rprj_sbs "${prodname}" "${performResample}" "${target_spacing}" "${performCropping}" "${subsettingBoxWKT}" "${sourceBandsList}" "${outProd}"

# function which creates the actual request from
# a template and returns the path to the request

inputNum=$#
[ "$inputNum" -ne 7 ] && return ${ERR_PREPROCESS}

local prodname=$1
local performResample=$2
local target_spacing=$3
local performCropping=$4
local subsettingBoxWKT=$5
local sourceBandsList=$6
local outprod=$7
# perform ceiling on target_spacing (resampling needs integer spacing)
local pixelSpacing_floor=$(echo "scale=0; $target_spacing/1" | bc )
(( $(bc <<< "$pixelSpacing_floor == $target_spacing") )) || let "target_spacing=pixelSpacing_floor+1" 

local commentRsmpBegin=""
local commentRsmpEnd=""
local commentReadSrcBegin=""
local commentReadSrcEnd=""
local commentSbsBegin=""
local commentSbsEnd=""
local commentMlBegin=""
local commentMlEnd=""
local commentProjSrcBegin=""
local commentProjSrcEnd=""

local beginCommentXML="<!--"
local endCommentXML="-->"

# check for resampling operator usage
if [ "${performResample}" = false ] ; then
    commentRsmpBegin="${beginCommentXML}"
    commentRsmpEnd="${endCommentXML}"
else
    commentReadSrcBegin="${beginCommentXML}"
    commentReadSrcEnd="${endCommentXML}"
fi
# check for subset operator usage
if [ "${performCropping}" = false ] ; then
    commentSbsBegin="${beginCommentXML}"
    commentSbsEnd="${endCommentXML}"
else
    commentProjSrcBegin="${beginCommentXML}"
    commentProjSrcEnd="${endCommentXML}"
fi

#sets the output filename
snap_request_filename="${TMPDIR}/$( uuidgen ).xml"

   cat << EOF > ${snap_request_filename}
<graph id="Graph">
  <version>1.0</version>
  <node id="Read">
    <operator>Read</operator>
    <sources/>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${prodname}</file>
    </parameters>
  </node>
  <node id="Reproject">
    <operator>Reproject</operator>
    <sources>
      <sourceProduct refid="Read"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <wktFile/>
      <crs>PROJCS[&quot;WGS 84 / Pseudo-Mercator&quot;, &#xd;
  GEOGCS[&quot;WGS 84&quot;, &#xd;
    DATUM[&quot;World Geodetic System 1984&quot;, &#xd;
      SPHEROID[&quot;WGS 84&quot;, 6378137.0, 298.257223563, AUTHORITY[&quot;EPSG&quot;,&quot;7030&quot;]], &#xd;
      AUTHORITY[&quot;EPSG&quot;,&quot;6326&quot;]], &#xd;
    PRIMEM[&quot;Greenwich&quot;, 0.0, AUTHORITY[&quot;EPSG&quot;,&quot;8901&quot;]], &#xd;
    UNIT[&quot;degree&quot;, 0.017453292519943295], &#xd;
    AXIS[&quot;Geodetic longitude&quot;, EAST], &#xd;
    AXIS[&quot;Geodetic latitude&quot;, NORTH], &#xd;
    AUTHORITY[&quot;EPSG&quot;,&quot;4326&quot;]], &#xd;
  PROJECTION[&quot;Popular Visualisation Pseudo Mercator&quot;, AUTHORITY[&quot;EPSG&quot;,&quot;1024&quot;]], &#xd;
  PARAMETER[&quot;semi_minor&quot;, 6378137.0], &#xd;
  PARAMETER[&quot;latitude_of_origin&quot;, 0.0], &#xd;
  PARAMETER[&quot;central_meridian&quot;, 0.0], &#xd;
  PARAMETER[&quot;scale_factor&quot;, 1.0], &#xd;
  PARAMETER[&quot;false_easting&quot;, 0.0], &#xd;
  PARAMETER[&quot;false_northing&quot;, 0.0], &#xd;
  UNIT[&quot;m&quot;, 1.0], &#xd;
  AXIS[&quot;Easting&quot;, EAST], &#xd;
  AXIS[&quot;Northing&quot;, NORTH], &#xd;
  AUTHORITY[&quot;EPSG&quot;,&quot;3857&quot;]]</crs>
      <resampling>Nearest</resampling>
      <referencePixelX/>
      <referencePixelY/>
      <easting/>
      <northing/>
      <orientation/>
      <pixelSizeX/>
      <pixelSizeY/>
      <width/>
      <height/>
      <tileSizeX/>
      <tileSizeY/>
      <orthorectify>false</orthorectify>
      <elevationModelName/>
      <noDataValue>NaN</noDataValue>
      <includeTiePointGrids>true</includeTiePointGrids>
      <addDeltaBands>false</addDeltaBands>
    </parameters>
  </node>
${commentRsmpBegin}  <node id="Resample">
    <operator>Resample</operator>
    <sources>
      <sourceProduct refid="Reproject"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <referenceBand/>
      <targetWidth/>
      <targetHeight/>
      <targetResolution>${target_spacing}</targetResolution>
      <upsampling>Nearest</upsampling>
      <downsampling>First</downsampling>
      <flagDownsampling>First</flagDownsampling>
      <resampleOnPyramidLevels>true</resampleOnPyramidLevels>
    </parameters>
  </node> ${commentRsmpEnd}
${commentSbsBegin}   <node id="Subset">
    <operator>Subset</operator>
    <sources>
${commentRsmpBegin}      <sourceProduct refid="Resample"/> ${commentRsmpEnd}  ${commentSbsEnd}
${commentReadSrcBegin}   <sourceProduct refid="Reproject"/> ${commentReadSrcEnd}
${commentSbsBegin}     </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <sourceBands/>
      <region/>
      <geoRegion>${subsettingBoxWKT}</geoRegion>
      <subSamplingX>1</subSamplingX>
      <subSamplingY>1</subSamplingY>
      <fullSwath>false</fullSwath>
      <tiePointGridNames/>
      <copyMetadata>true</copyMetadata>
    </parameters>
  </node> ${commentSbsEnd}
  <node id="BandSelect">
    <operator>BandSelect</operator>
    <sources>
	  ${commentSbsBegin} <sourceProduct refid="Subset"/> ${commentSbsEnd}
   ${commentProjSrcBegin}    <sourceProduct refid="Resample"/> ${commentProjSrcEnd}
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <selectedPolarisations/>
      <sourceBands>${sourceBandsList}</sourceBands>
      <bandNamePattern/>
    </parameters>
  </node>
  <node id="Write">
    <operator>Write</operator>
    <sources>
      <sourceProduct refid="BandSelect"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outprod}.dim</file>
      <formatName>BEAM-DIMAP</formatName>
    </parameters>
  </node>
  <applicationData id="Presentation">
    <Description/>
    <node id="Read">
            <displayPosition x="37.0" y="134.0"/>
    </node>
    <node id="Reproject">
      <displayPosition x="148.0" y="135.0"/>
    </node>
    <node id="Resample">
      <displayPosition x="250.0" y="129.0"/>
    </node>
    <node id="Subset">
      <displayPosition x="347.0" y="126.0"/>
    </node>
    <node id="BandSelect">
      <displayPosition x="472.0" y="133.0"/>
    </node>
    <node id="Write">
            <displayPosition x="610.0" y="134.0"/>
    </node>
  </applicationData>
</graph>
EOF

    [ $? -eq 0 ] && {
        echo "${snap_request_filename}"
        return 0
    } || return ${SNAP_REQUEST_ERROR}
}

# function that extracts the required band from input pre-processed product  
function band_selection(){
#function call band_selection "${out_pre_procDIM}" "${retrievedProduct}" "${prodnameArray[$index]}" "${missionArray[$index]}" "${bandIdArr[$index]}" "${outputProd}" "${pixelSpacingMeters}" "${isMaster}"
inputNum=$#
[ "$inputNum" -ne 8 ] && return ${ERR_BAND_SELECT}
local inputDIM=$1
local retrievedProduct=$2
local prodname=$3
local mission=$4
local bandId=$5
local outputProd=$6
local pixelSpacingMeters=$7
local isMaster=$8

#get band list
# report activity in the log
ciop-log "DEBUG" "Calling get_band_list "${prodname}" "${mission}" "${retrievedProduct}" "
bandList=$( get_band_list "${prodname}" "${mission}" "${retrievedProduct}")
returnCode=$?
[ $returnCode -eq 0 ] || return $returnCode
ciop-log "DEBUG" "bandList $bandList"
# get band identifier
# report activity in the log
ciop-log "INFO" "Calling "${bandId}" "${bandList}" "
bandIdentifier=$( get_band_id "${bandId}" "${bandList}")
returnCode=$?
[ $returnCode -eq 0 ] || return $returnCode
ciop-log "DEBUG" "bandIdentifier "${bandIdentifier}" "
outBandName=${prodname}_${bandIdentifier}
# report activity in the log
ciop-log "INFO" "Preparing SNAP request file for band extraction from pre-processed product"
# prepare the SNAP request
SNAP_REQUEST=$( create_snap_request_band_math "${inputDIM}" "${bandIdentifier}" "${outBandName}" "${outputProd}")
[ $? -eq 0 ] || return ${SNAP_REQUEST_ERROR}
[ $DEBUG -eq 1 ] && cat ${SNAP_REQUEST}
# report activity in the log
ciop-log "INFO" "Generated request file: ${SNAP_REQUEST}"
# report activity in the log
ciop-log "INFO" "Invoking SNAP-gpt on the generated request file for band extraction from pre-processed product"
# invoke the ESA SNAP toolbox
gpt $SNAP_REQUEST -c "${CACHE_SIZE}" &> /dev/null
# check the exit code
[ $? -eq 0 ] || return $ERR_SNAP
#properties filename
propertiesFile=${outputProd}.properties
cat << EOF > ${propertiesFile}
product=${prodname}
band=${bandIdentifier}
mission=${mission}
pixelSpacingMeters=${pixelSpacingMeters}
isMaster=${isMaster}
EOF

[ $? -eq 0 ] && {
    return 0
} || return ${ERR_BAND_SELECT}

}


function create_snap_request_band_math(){
#function call create_snap_request_band_math "${inputDIM}" "${bandIdentifier}" "${outBandName}" "${outputProd}"

# get number of inputs
inputNum=$#
# check on number of inputs
if [ "$inputNum" -ne "4" ] ; then
    return ${SNAP_REQUEST_ERROR}
fi

local inputDIM=$1
local bandIdentifier=$2
local outBandName=$3
local outputProd=$4
# put '' in band name if dash is present
dash_test=$( echo ${bandIdentifier} | grep "-" )
if [[ "${dash_test}" != "" ]] ; then
    bandIdentifier=\'${bandIdentifier}\'
fi

#sets the output filename
snap_request_filename="${TMPDIR}/$( uuidgen ).xml"

   cat << EOF > ${snap_request_filename}
<graph id="Graph">
  <version>1.0</version>
  <node id="Read">
    <operator>Read</operator>
    <sources/>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${inputDIM}</file>
    </parameters>
  </node>
  <node id="BandMaths">
    <operator>BandMaths</operator>
    <sources>
      <sourceProduct refid="Read"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <targetBands>
        <targetBand>
          <name>${outBandName}</name>
          <type>float32</type>
          <expression>${bandIdentifier}</expression>
          <description/>
          <unit/>
          <noDataValue>0.0</noDataValue>
        </targetBand>
      </targetBands>
      <variables/>
    </parameters>
  </node>
  <node id="Write">
    <operator>Write</operator>
    <sources>
       <sourceProduct refid="BandMaths"/>
    </sources>
    <parameters class="com.bc.ceres.binding.dom.XppDomElement">
      <file>${outputProd}.dim</file>
      <formatName>BEAM-DIMAP</formatName>
    </parameters>
  </node>
  <applicationData id="Presentation">
    <Description/>
    <node id="Write">
            <displayPosition x="455.0" y="135.0"/>
    </node>
    <node id="BandMaths">
      <displayPosition x="140.0" y="133.0"/>
    </node>
    <node id="Read">
            <displayPosition x="37.0" y="134.0"/>
    </node>
  </applicationData>
</graph>
EOF

[ $? -eq 0 ] && {
    echo "${snap_request_filename}"
    return 0
} || return ${SNAP_REQUEST_ERROR}

}



# Functioon to get number of bands embedded in a tif file
function get_bands_num_tif() {
#function call num_bands=$(get_bands_num_tif "${inputTIF}")

# get number of inputs
inputNum=$#
# check on number of inputs
if [ "$inputNum" -ne "1" ] ; then
    return ${ERR_GET_BANDS_NUM}
fi

local inputTIF=$1
local num_bands=0
# use gdalinfo to get band indexes list and put it in an array
bandId_list=$(gdalinfo ${inputTIF} | grep Band | sed -n -e 's|^.*Band \(.*\)Block.*|\1|p')
bandId_array=($bandId_list)
# number of bands is equal to array size
num_bands=${#bandId_array[@]}
[ $num_bands -gt 0 ] && {
    echo "${num_bands}"
    return 0
} || return ${ERR_GET_BANDS_NUM}

}


# Function to get the pixel spacing of a tif file
# Only the X spacing is returned, assuming square pixel
function get_pixel_spacing_tif() {
# function call pixSpacing=$(get_pixel_spacing_tif "${inputTIF}")

# get number of inputs
inputNum=$#
# check on number of inputs
if [ "$inputNum" -ne "1" ] ; then
    return ${ERR_GET_PIX_SPACING_TIF}
fi

local inputTIF=$1
local pixel_spacing=0
# use gdalinfo to get pixel spacing
pixel_spacing=$(gdalinfo ${inputTIF} | grep "Pixel Size" |  sed -n -e 's|^.*Pixel Size = (\(.*\),.*|\1|p')
[[ "${pixel_spacing}" != "" ]] && {
    echo "${pixel_spacing}"
    return 0
} || return ${ERR_GET_PIX_SPACING_TIF}

}


function main() {

    [ $DEBUG -eq 1 ] && echo $SNAP_HOME
    [ $DEBUG -eq 1 ] && echo $SNAP_VERSION
    #get input product list and convert it into an array
    # It should contain only the RED product
    local -a inputfiles=($@)
    #get the number of products to be processed
    inputfilesNum=$#
    # check if number of products is 1 (only RED product)
    [ "$inputfilesNum" -ne "1" ] && exit $ERR_WRONGINPUTNUM
    local red_product=${inputfiles[0]}
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    ciop-log "DEBUG" "RED product reference provided at input: ${red_product}"
    #get input green product
    local green_product="`ciop-getparam greenBandProduct`"
    # run a check on the product value, it can't be empty
    [ -z "$green_product" ] && exit $ERR_NOPROD
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    ciop-log "DEBUG" "GREEN product reference provided at input: ${green_product}"
    #get input blue product
    local blue_product="`ciop-getparam blueBandProduct`"
    # run a check on the product value, it can't be empty
    [ -z "$blue_product" ] && exit $ERR_NOPROD
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    ciop-log "DEBUG" "BLUE product reference provided at input: ${blue_product}"
    #get target resolution product
    local targetResProduct="`ciop-getparam targetResProduct`"
    # run a check on the product value, it can't be empty
    [ -z "$targetResProduct" ] && exit $ERR_NOPROD
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    ciop-log "DEBUG" "Target resolution product reference provided at input: ${targetResProduct}"
    # Master product flags
    local redIsMaster=0
    local greenIsMaster=0
    local blueIsMaster=0
    # check on targetResProduct: it must be one of the selected RGB product
    if [ ${targetResProduct} != ${red_product} ] && [ ${targetResProduct} != ${green_product} ] && [ ${targetResProduct} != ${blue_product} ]; then
    	exit $ERR_TARGET_RES_PROD
    fi
    #get red band index
    local redBandIndex="`ciop-getparam redBandIndex`"
    # run a check on the product value, it can't be empty
    [ -z "$redBandIndex" ] && exit $ERR_NOPROD
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    ciop-log "DEBUG" "Red band identifier provided: ${redBandIndex}"
    #get green band index
    local greenBandIndex="`ciop-getparam greenBandIndex`"
    # run a check on the product value, it can't be empty
    [ -z "$greenBandIndex" ] && exit $ERR_NOPROD
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    ciop-log "DEBUG" "Green band identifier provided: ${greenBandIndex}"
    #get blue band index
    local blueBandIndex="`ciop-getparam blueBandIndex`"
    # run a check on the product value, it can't be empty
    [ -z "$blueBandIndex" ] && exit $ERR_NOPROD
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    ciop-log "DEBUG" "Blue band identifier provided: ${blueBandIndex}"
    # retrieve the parameters value from workflow or job default value
    #performCropping="`ciop-getparam performCropping`"
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    #ciop-log "DEBUG" "The performCropping flag is set to ${performCropping}"
    # retrieve the parameters value from workflow or job default value
    SubsetBoundingBox="`ciop-getparam SubsetBoundingBox`"
    # log the value, it helps debugging.
    # the log entry is available in the process stderr
    
    if [ -z "$SubsetBoundingBox" ] ; then
	performCropping=false
    else
	performCropping=true
    fi
    ciop-log "DEBUG" "The performCropping flag is set to ${performCropping}"

    ciop-log "DEBUG" "The selected subset bounding box data is: ${SubsetBoundingBox}"
    ### SUBSETTING BOUNDING BOX DEFINITION IN WKT FORMAT
    local subsettingBoxWKT="POLYGON ((-180 -90, 180 -90, 180 90, -180 90, -180 -90))"
    if [ "${performCropping}" = true ] ; then
        # bounding box from csv to space separated value
        SubsetBoundingBox=$( echo "${SubsetBoundingBox}" | sed 's|,| |g' )
        #convert subset bounding box into WKT format
        SubsetBoundingBoxArray=($SubsetBoundingBox)
        lon_min="${SubsetBoundingBoxArray[0]}"
        lat_min="${SubsetBoundingBoxArray[1]}"
        lon_max="${SubsetBoundingBoxArray[2]}"
        lat_max="${SubsetBoundingBoxArray[3]}"
        subsettingBoxWKT="POLYGON (("${lon_min}" "${lat_min}", "${lon_max}" "${lat_min}", "${lon_max}" "${lat_max}", "${lon_min}" "${lat_max}", "${lon_min}" "${lat_min}"))"

        # log the value, it helps debugging.
        # the log entry is available in the process stderr
        ciop-log "DEBUG" "WKT subsettingBox = ${subsettingBoxWKT}"
    fi

    declare -a retrievedProductArray
    declare -a missionArray
    declare -a pixelSpacingArray
    declare -a prodnameArray
    declare -a isMasterArray
    pixelSpacingMaster=""
    # input aux arrays to force loop to go with the RGB order 
    declare -a inputProdArr=("${red_product}" "${green_product}" "${blue_product}")
    declare -a colorArr=("red" "green" "blue")
    declare -a bandIdArr=("$redBandIndex" "$greenBandIndex" "$blueBandIndex")
    let "inputProdNum=${#inputProdArr[@]}-1"
    # loop on red, green, blue products to download them and get target resolution 
    for index in `seq 0 $inputProdNum`;
    do
        # declare local master
        local isMaster=""
        currentProduct=${inputProdArr[$index]}
        [ ${currentProduct} = ${targetResProduct} ] && isMaster=1 || isMaster=0 
        # log the value, it helps debugging.
        # the log entry is available in the process stderr
        ciop-log "DEBUG" "Current processed product: ${currentProduct}"
	ciop-log "DEBUG" "Current isMaster flag: ${isMaster}"
        if [ $index -eq 0 ]; then echo currentProduct = red_product ; fi
        if [ $index -eq 1 ] && [ ${green_product} != ${red_product} ]; then echo currentProduct = green_product and green_product != red_product; fi
        if [ $index -eq 2 ] && [ ${blue_product} != ${red_product} ] && [ ${blue_product} != ${green_product} ]; then echo currentProduct = blue_product and blue_product != red_product and blue_product != green_product; fi 
        # avoid double download
	if [ $index -eq 0 ] || ([ $index -eq 1 ] && [ ${green_product} != ${red_product} ]) || ([ $index -eq 2 ] && [ ${blue_product} != ${red_product} ] && [ ${blue_product} != ${green_product} ]); then
            # report product retrieving activity in log
            ciop-log "INFO" "Retrieving ${currentProduct}"
            # retrieve product to the local temporary folder TMPDIR provided by the framework (this folder is only used by this process)
            # the utility returns the local path of the retrieved product
            retrievedProduct=$( get_data "${currentProduct}" "${TMPDIR}" )
            if [ $? -ne 0  ] ; then
                cat ${TMPDIR}/ciop_copy.stderr
                return $ERR_NORETRIEVEDPROD
            fi        
        elif ([ ${currentProduct} = ${green_product} ] && [ ${green_product} = ${red_product} ]) || ([ ${currentProduct} = ${blue_product} ] && [ ${blue_product} = ${red_product} ]); then
	    retrievedProduct=${retrievedProductArray[0]}
        elif [ ${currentProduct} = ${blue_product} ] && [ ${blue_product} = ${green_product} ]; then
	    retrievedProduct=${retrievedProductArray[1]}
        fi
        
        prodname=$( basename "$retrievedProduct" )
	
        # report activity in the log
        ciop-log "INFO" "Product correctly retrieved: ${retrievedProduct}"

        ### EXTRACT MISSION IDENTIFIER

        # report activity in the log
        ciop-log "INFO" "Retrieving mission identifier from product name"
        mission=$( mission_prod_retrieval "${retrievedProduct}")
        [ $? -eq 0 ] || return ${ERR_GETMISSION}
        # log the value, it helps debugging.
        # the log entry is available in the process stderr
        ciop-log "INFO" "Retrieved mission identifier: ${mission}"

        ### PRODUCT TYPE CHECK

        # report activity in the log
        ciop-log "INFO" "Checking product type from product name"
        #get product type from product name
        prodType=$( check_product_type "${retrievedProduct}" "${mission}")
        returnCode=$?
        [ $returnCode -eq 0 ] || return $returnCode
        # log the value, it helps debugging.
        # the log entry is available in the process stderr
        ciop-log "INFO" "Retrieved product type: ${prodType}"

        ### GET PIXEL SPACING FROM MISSION IDENTIFIER OF MASTER PRODUCT

        # report activity in the log
        ciop-log "INFO" "Getting pixel spacing"
        #get pixel spacing from mission identifier
        pixelSpacing=$( get_pixel_spacing "${mission}" "${prodType}" "${retrievedProduct}")
        returnCode=$?
        [ $returnCode -eq 0 ] || return $returnCode
        if [ $isMaster -eq 1 ] ; then
           isMasterArray+=("1")
           pixelSpacingMaster=$pixelSpacing
           # log the value, it helps debugging.
           # the log entry is available in the process stderr
           ciop-log "INFO" "Target pixel spacing: ${pixelSpacingMaster} m"
        else
           isMasterArray+=("0")
           # log the value, it helps debugging.
           # the log entry is available in the process stderr
           ciop-log "INFO" "Current pixel spacing: ${pixelSpacing} m"
        fi

        ### BAND IDENTIFIER CHECK
        # report activity in the log
        ciop-log "INFO" "Check on band identifier"
        #get band list
        ciop-log "DEBUG" "Running get_band_list ${prodname} ${mission} "${retrievedProduct}" "
        bandListCsv=$( get_band_list "${prodname}" "${mission}" "${retrievedProduct}" )
	returnCode=$?
        [ $returnCode -eq 0 ] || return $returnCode
        #get band list
        ciop-log "DEBUG" "Running check_band_id ${bandIdArr[$index]} ${bandListCsv} "
	check_band_id "${bandIdArr[$index]}" "${bandListCsv}"
	returnCode=$?
        [ $returnCode -eq 0 ] || return $returnCode	

        # fill arrays useful for next loop
 	retrievedProductArray+=("${retrievedProduct}")
        missionArray+=("${mission}")       
	pixelSpacingArray+=("${pixelSpacing}")
        prodnameArray+=("${prodname}")
    done

    prodNum=${#retrievedProductArray[@]} # it must be alway equal to 3
    [ $DEBUG -eq 1 ] && echo retrievedProductArray ${retrievedProductArray[@]} 
    [ $DEBUG -eq 1 ] && echo missionArray ${missionArray[@]}
    [ $DEBUG -eq 1 ] && echo pixelSpacingArray ${pixelSpacingArray[@]}
    [ $DEBUG -eq 1 ] && echo prodnameArray ${prodnameArray[@]}
    [ $DEBUG -eq 1 ] && echo prodNum $prodNum
    ### LOOP FOR PRE-PROCESSING CORE DEPENDING ON MISSION DATA
    let "prodNum-=1"
    for index in `seq 0 $prodNum`;
    do
        [ $DEBUG -eq 1 ] && echo colorArr[$index] ${colorArr[$index]}
        [ $DEBUG -eq 1 ] && echo outputProd ${OUTPUTDIR}/${colorArr[$index]}
        [ $DEBUG -eq 1 ] && echo prodNameNoExt ${prodnameArray[$index]}
        [ $DEBUG -eq 1 ] && echo prodNameNoExt "${prodnameArray[$index]%%.*}"
        if [ $index -eq 0 ] || ([ $index -eq 1 ] && [ ${green_product} != ${red_product} ]) || ([ $index -eq 2 ] && [ ${blue_product} != ${red_product} ] && [ ${blue_product} != ${green_product} ]); then
            # report activity in the log
            ciop-log "INFO" "Running pre-processing for ${retrievedProductArray[$index]}"
            pre_processing "${retrievedProductArray[$index]}" "${missionArray[$index]}" "${pixelSpacingArray[$index]}" "${pixelSpacingMaster}" "${performCropping}" "${subsettingBoxWKT}"
            returnCode=$?
            [ $returnCode -eq 0 ] || return $returnCode

	    # Band selection processing
            # NOTE: it is assumed that the "pre_processing" function always provides results in DIM format in $OUTPUTDIR_PRE_PROC
            out_pre_procDIM=$(ls ${OUTPUTDIR_PRE_PROC}/*.dim)
	elif ([ $index -eq 1 ] && [ ${green_product} = ${red_product} ]) || ([ $index -eq 2 ] && [ ${blue_product} = ${red_product} ]); then
	    out_pre_procDIM=$(ls ${OUTPUTDIR_PRE_PROC_RED}/*.dim) 
	elif [ $index -eq 2 ] && [ ${blue_product} = ${green_product} ]; then
            out_pre_procDIM=$(ls ${OUTPUTDIR_PRE_PROC_GREEN}/*.dim)
        fi
        outputProdBasename=${colorArr[$index]}
        outputProd=${OUTPUTDIR}/${outputProdBasename}
        prodNameNoExt=${prodnameArray[$index]}
        [ $DEBUG -eq 1 ] && echo prodNameNoExt before $prodNameNoExt
        prodNameNoExt="${prodNameNoExt%%.*}"
        [ $DEBUG -eq 1 ] && echo outputProdBasename $outputProdBasename
        [ $DEBUG -eq 1 ] && echo outputProd $outputProd
        [ $DEBUG -eq 1 ] && echo prodNameNoExt $prodNameNoExt
        # report activity in the log
        ciop-log "INFO" "Running band selection for ${retrievedProductArray[$index]}"
        # report activity in the log
        ciop-log "DEBUG" "Function call band_selection "${out_pre_procDIM}" "${retrievedProductArray[$index]}" "${prodNameNoExt}" "${missionArray[$index]}" "${bandIdArr[$index]}" "${outputProd}" "${pixelSpacingMaster}" "${currentIsMaster}" "
 	band_selection "${out_pre_procDIM}" "${retrievedProductArray[$index]}" "${prodNameNoExt}" "${missionArray[$index]}" "${bandIdArr[$index]}" "${outputProd}" "${pixelSpacingMaster}" "${isMasterArray[$index]}" 	
        returnCode=$?
	[ $returnCode -eq 0 ] || return $returnCode
	# save pre-proc out if it should be re-used by another color channel
	# case RED must be saved
	if [ $index -eq 0 ] && ( [ ${red_product} = ${green_product} ] || [ ${red_product} = ${blue_product} ]); then
            cp -r ${OUTPUTDIR_PRE_PROC}/*.* ${OUTPUTDIR_PRE_PROC_RED}
        fi
        # case GREEN must be saved
        if [ $index -eq 1 ] &&  [ ${green_product} = ${blue_product} ] ; then
            cp -r ${OUTPUTDIR_PRE_PROC}/*.* ${OUTPUTDIR_PRE_PROC_GREEN}
        fi
	# cleanup
	rm -rf ${OUTPUTDIR_PRE_PROC}/*.*
			
        # Tar creation and results publish
        # NOTE: it is assumed that the band selection function always provides results $OUTPUTDIR
	# create a tar archive where DIM output product + properties file are stored
        cd ${OUTPUTDIR} 
	tar -cf ${outputProdBasename}.tar ${outputProdBasename}.*
        cd -
	# report activity in the log
        ciop-log "INFO" "Publishing results for ${prodnameArray[$index]}"
        ciop-publish ${outputProd}.tar
        #cleanup
        rm -rf ${OUTPUTDIR}/*.*

    done

    #cleanup
    rm -rf ${TMPDIR}

    return ${SUCCESS}
}

# create the output folder to store the output products and export it
mkdir -p ${TMPDIR}/output
export OUTPUTDIR=${TMPDIR}/output
mkdir -p ${TMPDIR}/outputPreProc
export OUTPUTDIR_PRE_PROC=${TMPDIR}/outputPreProc
mkdir -p ${TMPDIR}/outputPreProcRed
export OUTPUTDIR_PRE_PROC_RED=${TMPDIR}/outputPreProcRed
mkdir -p ${TMPDIR}/outputPreProcGreen
export OUTPUTDIR_PRE_PROC_GREEN=${TMPDIR}/outputPreProcGreen
# debug flag setting
export DEBUG=0

# loop on input file to create a product array that will be processed by the main process
declare -a inputfiles
while read inputfile; do
    inputfiles+=("${inputfile}") # Array append
done
[ $DEBUG -eq 1 ] && echo Input list: ${inputfiles[@]}
# run main process
main ${inputfiles[@]}
res=$?
[ ${res} -ne 0 ] && exit ${res}

exit $SUCCESS

