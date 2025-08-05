#!/bin/bash

# FFmpeg CRT transform script / VileR 2021
# Bash conversion

# --- Configuration ---
LOGLVL="error"

# --- Argument Parsing ---
if [ "$#" -lt 2 ]; then
    echo "FFmpeg CRT transform script / VileR 2021"
    echo "USAGE:  $(basename "$0") <config_file> <input_file> [output_file]"
    echo "  input_file must be a valid image or video. If output_file is omitted, the"
    echo "  output will be named '(input_file)_(config_file).(input_ext)'"
    exit 1
fi

CONFIG_FILE="$1"
INPUT_FILE="$2"

if [ -n "$3" ]; then
    OUTFILE=$(realpath "$3")
    OUTEXT=".${3##*.}"
else
    INPUT_FILE_BASE=$(basename -- "$INPUT_FILE")
    INPUT_FILE_EXT=".${INPUT_FILE_BASE##*.}"
    INPUT_FILE_NAME="${INPUT_FILE_BASE%.*}"
    CONFIG_FILE_NAME=$(basename -- "$CONFIG_FILE")
    CONFIG_FILE_NAME="${CONFIG_FILE_NAME%.*}"
    OUTFILE="$(dirname "$INPUT_FILE")/${INPUT_FILE_NAME}_${CONFIG_FILE_NAME}${INPUT_FILE_EXT}"
    OUTEXT="$INPUT_FILE_EXT"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "File not found: $CONFIG_FILE"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "File not found: $INPUT_FILE"
    exit 1
fi

if [ -z "$OUTEXT" ]; then
    echo "Output filename must have an extension: $OUTFILE"
    exit 1
fi

# --- Media Info ---
MEDIA_INFO=$(ffprobe -hide_banner -loglevel quiet -select_streams v:0 -show_entries stream=width,height,nb_frames "$INPUT_FILE")
IX=$(echo "$MEDIA_INFO" | grep "width" | cut -d= -f2)
IY=$(echo "$MEDIA_INFO" | grep "height" | cut -d= -f2)
FC=$(echo "$MEDIA_INFO" | grep "nb_frames" | cut -d= -f2)

if [ -z "$IX" ] || [ -z "$IY" ] || [ -z "$FC" ]; then
    echo "Couldn't get media info for input file \"$INPUT_FILE\" (invalid image/video?)"
    exit 1
fi

if [[ "$INPUT_FILE" == *.mkv ]]; then
    FC="unknown"
fi

IS_VIDEO=""
if [ "$FC" != "N/A" ]; then
    IS_VIDEO=1
fi

# --- Settings ---
# Parse Windows batch-style config file and convert to bash variables
while IFS= read -r line; do
    # Skip comment lines and empty lines
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*\; ]] && continue
    
    # Extract key and value from whitespace-separated format
    key=$(echo "$line" | awk '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    value=$(echo "$line" | awk '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Skip if no key or value
    [[ -z "$key" ]] && continue
    [[ -z "$value" ]] && continue
    
    # Export as environment variable (replace invalid characters in key)
    safe_key=$(echo "$key" | sed 's/[^a-zA-Z0-9_]/_/g')
    # Skip invalid variable names that start with numbers
    if [[ "$safe_key" =~ ^[0-9] ]]; then
        safe_key="_$safe_key"
    fi
    export "$safe_key"="$value"
done < "$CONFIG_FILE"

if [ ! -f "_${OVL_TYPE}.png" ]; then
    echo "File not found: _${OVL_TYPE}.png"
    exit 1
fi

# Set missing variables with default values
if [ -z "$RGBFMT" ]; then RGBFMT="rgb24"; fi
if [ -z "$TMP_EXT" ]; then TMP_EXT="png"; fi
if [ -z "$TMP_OUTPARAMS" ]; then TMP_OUTPARAMS=""; fi
if [ -z "$RNG" ]; then RNG="256"; fi
if [ -z "$KLUDGEFMT" ]; then KLUDGEFMT="rgb24"; fi
if [ -z "$FIN_MATRIXSTR" ]; then FIN_MATRIXSTR=""; fi
if [ -z "$FIN_OUTPARAMS" ]; then FIN_OUTPARAMS=""; fi

# Memory-conscious scaling: reduce prescale factor if it would create too large images
MAX_PIXELS=4000000  # ~2000x2000 max working size
PREDICTED_PIXELS=$(($IX * $IY * $PRESCALE_BY * $PRESCALE_BY))
if [ "$PREDICTED_PIXELS" -gt "$MAX_PIXELS" ]; then
    # Calculate a safer prescale factor
    SAFE_PRESCALE=$(echo "sqrt($MAX_PIXELS / ($IX * $IY))" | bc -l | cut -d. -f1)
    if [ "$SAFE_PRESCALE" -lt 1 ]; then SAFE_PRESCALE=1; fi
    echo "Warning: Reducing PRESCALE_BY from $PRESCALE_BY to $SAFE_PRESCALE to avoid memory issues"
    PRESCALE_BY="$SAFE_PRESCALE"
fi

SXINT=$(($IX * $PRESCALE_BY))
PX=$(($IX * $PRESCALE_BY * $PX_ASPECT))
PY=$(($IY * $PRESCALE_BY))
OX=$(echo "$OY * $OASPECT" | bc -l | cut -d. -f1)
SWSFLAGS="accurate_rnd+full_chroma_int+full_chroma_inp"

if [ "$V_PX_BLUR" == "0" ]; then
    VSIGMA=0.1
else
    VSIGMA=$(echo "$V_PX_BLUR/100*$PRESCALE_BY" | bc -l)
fi

# Set default for VIGNETTE_POWER if not defined
if [ -z "$VIGNETTE_POWER" ]; then VIGNETTE_POWER="0.1"; fi

if [ "$VIGNETTE_ON" == "yes" ]; then
    if [ "$_16BPC_PROCESSING" == "yes" ]; then
        VIGNETTE_STR="
        [ref]; color=c=#FFFFFF:s=${PX}x${PY},format=rgb24[mkscale];
        [mkscale][ref]scale2ref=flags=neighbor[mkvig][novig];
        [mkvig]setsar=sar=1/1, vignette=PI*${VIGNETTE_POWER},format=gbrp16le[vig];
        [novig][vig]blend=all_mode='multiply':shortest=1,"
    else
        VIGNETTE_STR=", vignette=PI*${VIGNETTE_POWER},"
    fi
else
    VIGNETTE_STR=","
fi

if [ "$FLAT_PANEL" == "yes" ]; then
    SCANLINES_ON="no"
    CRT_CURVATURE=0
    OVL_ALPHA=0
fi

# Use bc for floating point comparison
if [ "$(echo "$BEZEL_CURVATURE < $CRT_CURVATURE" | bc -l)" -eq 1 ]; then
    BEZEL_CURVATURE="$CRT_CURVATURE"
fi

if [ "$CRT_CURVATURE" != "0" ]; then
    LENSC=", pad=iw+8:ih+8:4:4:black, lenscorrection=k1=${CRT_CURVATURE}:k2=${CRT_CURVATURE}:i=bilinear, crop=iw-8:ih-8"
fi

if [ "$BEZEL_CURVATURE" != "0" ]; then
    BZLENSC=", scale=iw*2:ih*2:flags=gauss, pad=iw+8:ih+8:4:4:black, lenscorrection=k1=${BEZEL_CURVATURE}:k2=${BEZEL_CURVATURE}:i=bilinear, crop=iw-8:ih-8, scale=iw/2:ih/2:flags=gauss"
fi

if [ "$SCAN_FACTOR" == "half" ]; then
    SCAN_FACTOR=0.5
    SL_COUNT=$(($IY / 2))
elif [ "$SCAN_FACTOR" == "double" ]; then
    SCAN_FACTOR=2
    SL_COUNT=$(($IY * 2))
else
    SCAN_FACTOR=1
    SL_COUNT=$IY
fi

MONOCURVES=""
TEXTURE_OVL=""
# Convert to lowercase for case matching
MONITOR_COLOR_LOWER=$(echo "$MONITOR_COLOR" | tr '[:upper:]' '[:lower:]')
case "$MONITOR_COLOR_LOWER" in
    white)      MONOCURVES="" ;;
    paperwhite) MONOCURVES="" ; TEXTURE_OVL="paper" ;;
    green1)     MONOCURVES="curves=r='0/0 .77/0 1/.45':g='0/0 .77/1 1/1':b='0/0 .77/.17 1/.73'," ;;
    green2)     MONOCURVES="curves=r='0/0 .43/.16 .72/.30 1/.56':g='0/0 .51/.53 .82/1 1/1':b='0/0 .43/.16 .72/.30 1/.56'," ;;
    bw-tv)      MONOCURVES="curves=r='0/0 .5/.49 1/1':g='0/0 .5/.49 1/1':b='0/0 .5/.62 1/1'," ;;
    amber)      MONOCURVES="curves=r='0/0 .25/.45 .8/1 1/1':g='0/0 .25/.14 .8/.55 1/.8':b='0/0 .8/0 1/.29'," ;;
    plasma)     MONOCURVES="curves=r='0/0 .13/.27 .52/.83 .8/1 1/1':g='0/0 .13/0 .52/.14 .8/.35 1/.54':b='0/0 1/0'," ;;
    eld)        MONOCURVES="curves=r='0/0 .46/.49 1/1':g='0/0 .46/.37 1/.94':b='0/0 .46/0 1/.29'," ;;
    lcd)        MONOCURVES="curves=r='0/.09 1/.48':g='0/.11 1/.56':b='0/.20 1/.35'," ; PXGRID_INVERT=1 ;;
    lcd-lite)   MONOCURVES="curves=r='0/.06 1/.64':g='0/.15 1/.77':b='0/.35 1/.65'," ; PXGRID_INVERT=1 ;;
    lcd-lwhite) MONOCURVES="curves=r='0/.09 1/.82':g='0/.18 1/.89':b='0/.29 1/.93'," ; PXGRID_INVERT=1 ;;
    lcd-lblue)  MONOCURVES="curves=r='0/.00 1/.62':g='0/.22 1/.75':b='0/.73 1/.68'," ; PXGRID_INVERT=1 ;;
esac

if [[ "$MONITOR_COLOR_LOWER" == lcd* ]] && [ "$(echo "$LCD_GRAIN > 0" | bc -l)" -eq 1 ]; then
    TEXTURE_OVL="lcdgrain"
fi

MONO_STR1=""
MONO_STR2=""
if [ "$MONITOR_COLOR_LOWER" != "rgb" ]; then
    OVL_ALPHA=0
    MONO_STR1="format=gray16le,format=gbrp16le,"
    MONO_STR2="$MONOCURVES"
fi

if [ "$MONITOR_COLOR_LOWER" == "p7" ]; then
    MONOCURVES_LAT="curves=r='0/0 .6/.31 1/.75':g='0/0 .25/.16 .75/.83 1/.94':b='0/0 .5/.76 1/.97'"
    MONOCURVES_DEC="curves=r='0/0 .5/.36 1/.86':g='0/0 .5/.52 1/.89':b='0/0 .5/.08 1/.13'"
    DECAYDELAY=$(($LATENCY / 2))

    if [ -n "$IS_VIDEO" ]; then
        MONO_STR2="
        split=4 [orig][a][b][c];
        [a] tmix=${LATENCY}, ${MONOCURVES_LAT} [lat];
        [b] lagfun=${P_DECAY_FACTOR} [dec1]; [c] lagfun=${P_DECAY_FACTOR}*0.95 [dec2];
        [dec2][dec1] blend=all_mode='lighten':all_opacity=0.3, ${MONOCURVES_DEC}, setpts=PTS+(${DECAYDELAY}/FR)/TB [decay];
        [lat][decay] blend=all_mode='lighten':all_opacity=${P_DECAY_ALPHA} [p7];
        [orig][p7] blend=all_mode='screen',format=${RGBFMT},"
    else
        MONO_STR2="
        split=3 [orig][a][b];
        [a] ${MONOCURVES_LAT} [lat];
        [b] ${MONOCURVES_DEC} [decay];
        [lat][decay] blend=all_mode='lighten':all_opacity=${P_DECAY_ALPHA} [p7];
        [orig][p7] blend=all_mode='screen',format=${RGBFMT},"
    fi
fi

SKIP_OVL=""
if [ "$(echo "$OVL_ALPHA == 0" | bc -l)" -eq 1 ]; then
    SKIP_OVL=1
fi

SKIP_BRI=""
if [ "$(echo "$BRIGHTEN == 1" | bc -l)" -eq 1 ]; then
    SKIP_BRI=1
fi

FFSTART=$(date +"%T")
if [ "$FC" != "N/A" ]; then
    echo "Input frame count: $FC"
    echo "---------------------------"
fi

# --- Bezel Creation ---
echo "Bezel:"
if [ "$CORNER_RADIUS" == "0" ]; then
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y \
    -f lavfi -i "color=c=#ffffff:s=${PX}x${PY}, format=rgb24 ${BZLENSC}" \
    -frames:v 1 TMPbezel.png
else
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y \
    -f lavfi -i "color=s=1024x1024, format=gray, geq='lum=if(lte((X-W)^2+(Y-H)^2, 1024*1024), 255, 0)', scale=${CORNER_RADIUS}:${CORNER_RADIUS}:flags=lanczos" \
    -filter_complex "
        color=c=#ffffff:s=${PX}x${PY}, format=rgb24[bg];
        [0] split=4 [tl][c2][c3][c4];
        [c2] transpose=1 [tr];
        [c3] transpose=3 [br];
        [c4] transpose=2 [bl];
        [bg][tl] overlay=0:0:format=rgb [p1];
        [p1][tr] overlay=${PX}-${CORNER_RADIUS}:0:format=rgb [p2];
        [p2][br] overlay=${PX}-${CORNER_RADIUS}:${PY}-${CORNER_RADIUS}:format=rgb [p3];
        [p3][bl] overlay=x=0:y=${PY}-${CORNER_RADIUS}:format=rgb ${BZLENSC}" \
    -frames:v 1 TMPbezel.png
fi
if [ $? -ne 0 ]; then exit 1; fi

# --- Scanlines ---
if [ "$SCANLINES_ON" == "yes" ]; then
    echo "Scanlines:"
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -f lavfi \
    -i nullsrc=s=1x100 \
    -vf "
        format=gray,
        geq=lum='if(lt(Y,${PRESCALE_BY}/${SCAN_FACTOR}), pow(sin(Y*PI/(${PRESCALE_BY}/${SCAN_FACTOR})), 1/${SL_WEIGHT})*255, 0)',
        crop=1:${PRESCALE_BY}/${SCAN_FACTOR}:0:0,
        scale=${PX}:ih:flags=neighbor" \
    -frames:v 1 TMPscanline.png

    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -loop 1 -framerate 1 -t "$SL_COUNT" \
    -i TMPscanline.png \
    -vf "
        format=gray16le,
        tile=layout=1x${SL_COUNT},
        scale=iw*3:ih*3:flags=gauss ${LENSC}, scale=iw/3:ih/3:flags=gauss,
        format=gray16le, format=${RGBFMT}" \
    -frames:v 1 $TMP_OUTPARAMS TMPscanlines.${TMP_EXT}
    if [ $? -ne 0 ]; then exit 1; fi
fi

# --- Shadowmask/Texture Overlay ---
echo "Shadowmask overlay:"
if [ "$(echo "$OVL_ALPHA > 0" | bc -l)" -eq 1 ]; then
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -i "_${OVL_TYPE}.png" -vf "
        lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)',
        scale=round(iw*${OVL_SCALE}):round(ih*${OVL_SCALE}):flags=lanczos+${SWSFLAGS}" \
    TMPshadowmask1x.png

    OVL_INFO=$(ffprobe -hide_banner -loglevel quiet -show_entries stream=width,height TMPshadowmask1x.png)
    OVL_X=$(echo "$OVL_INFO" | grep "width" | cut -d= -f2)
    OVL_Y=$(echo "$OVL_INFO" | grep "height" | cut -d= -f2)
    TILES_X=$(($PX / $OVL_X + 1))
    TILES_Y=$(($PY / $OVL_Y + 1))

    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -loop 1 -i TMPshadowmask1x.png -vf "
        tile=layout=${TILES_X}x${TILES_Y},
        crop=${PX}:${PY},
        scale=iw*2:ih*2:flags=gauss ${LENSC},
        scale=iw/2:ih/2:flags=bicubic,
        lutrgb='r=gammaval(0.454545):g=gammaval(0.454545):b=gammaval(0.454545)'" \
    -frames:v 1 TMPshadowmask.png
    if [ $? -ne 0 ]; then exit 1; fi
else
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -f lavfi -i "color=c=#00000000:s=${PX}x${PY},format=rgba" -frames:v 1 TMPshadowmask.png
fi

if [ -n "$TEXTURE_OVL" ]; then
    echo "Texture overlay:"
    if [ "$TEXTURE_OVL" == "paper" ]; then
        PAPERX=$(($OX * 67 / 100))
        PAPERY=$(($OY * 67 / 100))
        ffmpeg -hide_banner -y -loglevel "$LOGLVL" -stats -f lavfi -i "color=c=#808080:s=${PAPERX}x${PAPERY}" \
        -filter_complex "
            noise=all_seed=5150:all_strength=100:all_flags=u, format=gray,
            lutrgb='r=(val-70)*255/115:g=(val-70)*255/115:b=(val-70)*255/115',
            format=rgb24,
            lutrgb='
                r=if(between(val,0,101),207,if(between(val,102,203),253,251)):
                g=if(between(val,0,101),238,if(between(val,102,203),225,204)):
                b=if(between(val,0,101),255,if(between(val,102,203),157,255))',
            format=gbrp16le,
            lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)',
            scale=${OX}:${OY}:flags=bilinear,
            gblur=sigma=3:steps=6,
            lutrgb='r=gammaval(0.454545):g=gammaval(0.454545):b=gammaval(0.454545)',
            format=gbrp16le,format=rgb24" \
        -frames:v 1 TMPtexture.png
    elif [ "$TEXTURE_OVL" == "lcdgrain" ]; then
        GRAINX=$(($OX * 50 / 100))
        GRAINY=$(($OY * 50 / 100))
        ffmpeg -hide_banner -y -loglevel "$LOGLVL" -stats -filter_complex "color=#808080:s=${GRAINX}x${GRAINY},
            noise=all_seed=5150:all_strength=${LCD_GRAIN}, format=gray,
            scale=${OX}:${OY}:flags=lanczos, format=rgb24" \
        -frames:v 1 TMPtexture.png
    fi
fi

# --- Discrete pixel grid ---
if [ "$FLAT_PANEL" == "yes" ]; then
    echo "Grid:"
    LUM_GAP=$(echo "255-255*${PXGRID_ALPHA}" | bc -l)
    LUM_PX=255
    if [ -n "$PXGRID_INVERT" ]; then
        LUM_GAP=$(echo "255*${PXGRID_ALPHA}" | bc -l)
        LUM_PX=0
    fi
    GX=$(($PRESCALE_BY / $PX_FACTOR_X))
    GY=$(($PRESCALE_BY / $PX_FACTOR_Y))
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -f lavfi \
    -i nullsrc=s=${SXINT}x${PY} -vf "
        format=gray,
        geq=lum='if(gte(mod(X,${GX}),${GX}-${PX_X_GAP})+gte(mod(Y,${GY}),${GY}-${PX_Y_GAP}),${LUM_GAP},${LUM_PX})',
        format=gbrp16le,
        lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)',
        scale=${PX}:ih:flags=bicubic,
        lutrgb='r=gammaval(0.454545):g=gammaval(0.454545):b=gammaval(0.454545)',
        format=gbrp16le,format=rgb24" \
    -frames:v 1 TMPgrid.png
    if [ $? -ne 0 ]; then exit 1; fi
fi

# --- Pre-processing ---
SCALESRC="$INPUT_FILE"
PREPROCESS=""
VF_PRE=""

if [ "$INVERT_INPUT" == "yes" ]; then
    PREPROCESS=1
    VF_PRE="negate"
fi

if [ -n "$IS_VIDEO" ] && [ "$(echo "$LATENCY > 0" | bc -l)" -eq 1 ] && [ "$MONITOR_COLOR_LOWER" != "p7" ]; then
    PREPROCESS=1
    if [ -n "$VF_PRE" ]; then
        VF_PRE=", ${VF_PRE}"
    fi
    VF_PRE="
        split [o][2lat];
        [2lat] tmix=${LATENCY}, setpts=PTS+((${LATENCY}/2)/FR)/TB [lat];
        [lat][o] blend=all_opacity=${LATENCY_ALPHA}
        ${VF_PRE}"
fi

if [ -n "$IS_VIDEO" ] && [ "$(echo "$P_DECAY_FACTOR > 0" | bc -l)" -eq 1 ] && [ "$MONITOR_COLOR_LOWER" != "p7" ]; then
    PREPROCESS=1
    if [ -n "$VF_PRE" ]; then
        VF_PRE=", ${VF_PRE}"
    fi
    VF_PRE="
        [0] split [orig][2lag];
        [2lag] lagfun=${P_DECAY_FACTOR} [lag];
        [orig][lag] blend=all_mode='lighten':all_opacity=${P_DECAY_ALPHA}
        ${VF_PRE}"
fi

if [ -n "$PREPROCESS" ]; then
    echo "Step00 (preprocess):"
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -i "$INPUT_FILE" -filter_complex "$VF_PRE" $TMP_OUTPARAMS TMPstep00.${TMP_EXT}
    if [ $? -ne 0 ]; then exit 1; fi
    SCALESRC="TMPstep00.${TMP_EXT}"
fi

# --- Step 01 ---
GRIDFILTERFRAG=""
if [ "$FLAT_PANEL" == "yes" ]; then
    GRIDBLENDMODE="'multiply'"
    if [ -n "$PXGRID_INVERT" ]; then
        GRIDBLENDMODE="'screen'"
    fi
    GRIDFILTERFRAG="
        [scaled];
        movie=TMPgrid.png[grid];
        [scaled][grid]blend=all_mode=${GRIDBLENDMODE}"
fi

echo "Step01:"
ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -i "$SCALESRC" -filter_complex "
    scale=iw*${PRESCALE_BY}:ih:flags=neighbor,
    format=gbrp16le,
    lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)',
    scale=iw*${PX_ASPECT}:ih:flags=fast_bilinear,
    scale=iw:ih*${PRESCALE_BY}:flags=neighbor
    ${GRIDFILTERFRAG},
    gblur=sigma=${H_PX_BLUR}/100*${PRESCALE_BY}*${PX_ASPECT}:sigmaV=${VSIGMA}:steps=3" \
-c:v ffv1 -c:a copy TMPstep01.mkv
if [ $? -ne 0 ]; then exit 1; fi

# --- Step 02 ---
echo "Step02:"
if [ "$HALATION_ON" == "yes" ]; then
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -i TMPstep01.mkv -filter_complex "
        [0]split[a][b],
        [a]gblur=sigma=${HALATION_RADIUS}:steps=6[h],
        [b][h]blend=all_mode='lighten':all_opacity=${HALATION_ALPHA},
        lutrgb='
            r=clip(gammaval(0.454545)*(258/256)-2*256 ,minval,maxval):
            g=clip(gammaval(0.454545)*(258/256)-2*256 ,minval,maxval):
            b=clip(gammaval(0.454545)*(258/256)-2*256 ,minval,maxval)',
        lutrgb='r=val+(${BLACKPOINT}*256*(maxval-val)/maxval):g=val+(${BLACKPOINT}*256*(maxval-val)/maxval):b=val+(${BLACKPOINT}*256*(maxval-val)/maxval)',
        format=${RGBFMT}
        ${LENSC}" \
    $TMP_OUTPARAMS TMPstep02.${TMP_EXT}
else
    ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -i TMPstep01.mkv -vf "
        lutrgb='r=gammaval(0.454545):g=gammaval(0.454545):b=gammaval(0.454545)',
        lutrgb='r=val+(${BLACKPOINT}*256*(maxval-val)/maxval):g=val+(${BLACKPOINT}*256*(maxval-val)/maxval):b=val+(${BLACKPOINT}*256*(maxval-val)/maxval)',
        format=${RGBFMT}
        ${LENSC}" \
    $TMP_OUTPARAMS TMPstep02.${TMP_EXT}
fi
if [ $? -ne 0 ]; then exit 1; fi

# --- Step 03 ---
if [ "$SCANLINES_ON" == "no" ] && [ "$BEZEL_CURVATURE" == "$CRT_CURVATURE" ] && [ "$CORNER_RADIUS" -eq 0 ] && [ -n "$SKIP_OVL" ] && [ -n "$SKIP_BRI" ]; then
    if [ -f "TMPstep03.${TMP_EXT}" ]; then rm "TMPstep03.${TMP_EXT}"; fi
    mv "TMPstep02.${TMP_EXT}" "TMPstep03.${TMP_EXT}"
else
    if [ "$SCANLINES_ON" == "yes" ]; then
        SL_INPUT="TMPscanlines.${TMP_EXT}"
        if [ "$BLOOM_ON" == "yes" ]; then
            SL_INPUT="TMPbloom.${TMP_EXT}"
            echo "Step02-bloom:"
            ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y \
            -i "TMPscanlines.${TMP_EXT}" -i "TMPstep02.${TMP_EXT}" -filter_complex "
                [1]lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)', hue=s=0, lutrgb='r=gammaval(0.454545):g=gammaval(0.454545):b=gammaval(0.454545)'[g],
                [g][0]blend=all_expr='if(gte(A,${RNG}/2), (B+(${RNG}-1-B)*${BLOOM_POWER}*(A-${RNG}/2)/(${RNG}/2)), B)',
                setsar=sar=1/1" \
            $TMP_OUTPARAMS "$SL_INPUT"
        fi
        echo "Step03:"
        ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y \
        -i "TMPstep02.${TMP_EXT}" -i "$SL_INPUT" -i TMPshadowmask.png -i TMPbezel.png -filter_complex "
            [0][1]blend=all_mode='multiply':all_opacity=${SL_ALPHA}[a],
            [a][2]blend=all_mode='multiply':all_opacity=${OVL_ALPHA}[b],
            [b][3]blend=all_mode='multiply',
            lutrgb='r=clip(val*${BRIGHTEN},0,${RNG}-1):g=clip(val*${BRIGHTEN},0,${RNG}-1):b=clip(val*${BRIGHTEN},0,${RNG}-1)'" \
        $TMP_OUTPARAMS "TMPstep03.${TMP_EXT}"
    else
        echo "Step03:"
        ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y \
        -i "TMPstep02.${TMP_EXT}" -i TMPshadowmask.png -i TMPbezel.png -filter_complex "
            [0][1]blend=all_mode='multiply':all_opacity=${OVL_ALPHA}[b],
            [b][2]blend=all_mode='multiply',
            lutrgb='r=clip(val*${BRIGHTEN},0,${RNG}-1):g=clip(val*${BRIGHTEN},0,${RNG}-1):b=clip(val*${BRIGHTEN},0,${RNG}-1)'" \
        $TMP_OUTPARAMS "TMPstep03.${TMP_EXT}"
    fi
fi
if [ $? -ne 0 ]; then exit 1; fi

# --- Final Output ---
CROP_STR=$(ffmpeg -hide_banner -y \
    -f lavfi -i "color=c=#ffffff:s=${PX}x${PY}" -i TMPbezel.png \
    -filter_complex "[0]format=rgb24 ${LENSC}[crt]; [crt][1]overlay, cropdetect=limit=0:round=2" \
    -frames:v 3 -f null - 2>&1 | grep "crop" | tail -n1 | awk '{print $NF}')
if [ $? -ne 0 ]; then exit 1; fi

TEXTURE_STR=""
if [ -n "$TEXTURE_OVL" ]; then
    if [ "$TEXTURE_OVL" == "paper" ]; then
        TEXTURE_STR="[nop];movie=TMPtexture.png,format=${RGBFMT}[paper];[nop][paper]blend=all_mode='multiply':eof_action='repeat'"
    elif [ "$TEXTURE_OVL" == "lcdgrain" ]; then
        TEXTURE_STR="
            ,format=${KLUDGEFMT},split[og1][og2];
            movie=TMPtexture.png,format=${KLUDGEFMT}[lcd];
            [lcd][og1]blend=all_mode='vividlight':eof_action='repeat'[notquite];
            [og2]limiter=0:110*${RNG}/256[fix];
            [fix][notquite]blend=all_mode='lighten':eof_action='repeat', format=${RGBFMT}"
    fi
fi

echo "Output:"
ffmpeg -hide_banner -loglevel "$LOGLVL" -stats -y -i "TMPstep03.${TMP_EXT}" -filter_complex "
    ${CROP_STR},
    format=gbrp16le,
    lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)',
    ${MONO_STR1}
    scale=w=${OX}-${OMARGIN}*2:h=${OY}-${OMARGIN}*2:force_original_aspect_ratio=decrease:flags=${OFILTER}+${SWSFLAGS},
    lutrgb='r=gammaval(0.454545):g=gammaval(0.454545):b=gammaval(0.454545)',
    format=gbrp16le,
    format=${RGBFMT},
    ${MONO_STR2}
    setsar=sar=1/1
    ${VIGNETTE_STR}
    pad=${OX}:${OY}:-1:-1:black
    ${TEXTURE_STR}
    ${FIN_MATRIXSTR}" \
$FIN_OUTPARAMS "$OUTFILE"
if [ $? -ne 0 ]; then exit 1; fi

# --- Clean up ---
rm -f TMPbezel.png TMPscanline*.* TMPshadow*.png TMPtexture.png TMPgrid.png TMPstep0*.* TMPbloom.* TMPcrop

echo "------------------------"
echo "Output file: $OUTFILE"
echo "Started:     $FFSTART"
echo "Finished:    $(date +"%T")"

exit 0

