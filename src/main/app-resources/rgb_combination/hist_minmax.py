import numpy as np
import gdal, gdalconst
import os


def hist_skip(inFname, bandIndex, outFname, nbuckets=10000):
  src = gdal.Open(inFname)
  band = src.GetRasterBand(int(bandIndex))
  percentiles = [ float(percentileMin), float(percentileMax) ]
  # Use GDAL to find the min and max
  (minVal, maxVal) = band.ComputeRasterMinMax(False)
  print "lo="+str(minVal)
  print "hi="+str(maxVal)	
  
  
  # gdal_calc to clip values lower than min
  # Print out and execute gdal_calc command
  gdalCalcCommand="gdal_calc.py -A "+inFname+" --A_band="+bandIndex+" --calc="+'"'+str(minVal)+"*logical_and(A!=0.0, A<="+str(minVal)+")+A*logical_and(A!=0.0,A>"+str(minVal)+")"+'"'+" --outfile=gdal_calc_result.tif --NoDataValue=0"
  print "running  "+gdalCalcCommand
  os.system(gdalCalcCommand)
  
  #gdal_translate to make linear strecthing bewtween 1 and 255 (to keep 0 fro no_data)
  # Print out and execute gdal_translate command 
  gdalTranslateCommand="gdal_translate -b 1 -co TILED=YES -co BLOCKXSIZE=512 -co BLOCKYSIZE=512 -co ALPHA=YES -ot Byte -a_nodata 0 -scale "+str(minVal)+" "+str(maxVal)+" 1 255 gdal_calc_result.tif "+outFname 
  print "running  "+gdalTranslateCommand
  os.system(gdalTranslateCommand)
  
  # remove temp file
  os.system("rm gdal_calc_result.tif")
  
  #return (vals, percentiles)
  return 0;

# Invoke as: `python hist_skip.py my-raster.tif`.
if __name__ == '__main__':
  import sys
  
  if len(sys.argv) == 6:
    hist_skip(sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5])
  else:
    print "python hist_skip.py INPUT-RASTER BAND-INDEX PERCENTILE-MIN PERCENTILE-MAX OUTPUT-RASTER"
