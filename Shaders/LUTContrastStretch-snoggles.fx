/*
ContrastStretch
By: Lord Of Lunacy

A histogram based contrast stretching shader that adaptively adjusts the contrast of the image
based on its contents.

Srinivasan, S & Balram, Nikhil. (2006). Adaptive contrast enhancement using local region stretching.
http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.526.5037&rep=rep1&type=pdf
*/

/*
Original author: Lord of Lunacy
Original source: https://github.com/LordOfLunacy/Insane-Shaders
Original license: CC0 1.0 Universal

Modifications by: Snoggles
Offered upstream in: https://github.com/LordOfLunacy/Insane-Shaders/pull/17
Changes:
- Add human-readable option descriptions
- Prevent from altering pure black/white values.
- Add CONTRAST_HISTOGRAM_SAMPLE_STRIDE=8 0.360 -> 0.265 ms/frame
- Combine PrefixSums + Variances phases: 0.265 -> 0.204 ms/frame
- Combine LUT generation into PrefixVariance: 0.204 -> 0.197 ms/frame
- Draw histogram samples directly, removing HistogramMerge: 0.197 -> 0.191 ms/frame
- Remove unused CONTRAST_COMPUTE option
- Remove CONTRAST_LUT_SIZE which seems to incorrectly impact exposure at non-default values.
- Apply external LUT before contrast (perf: without adding an additional pass).
*/

// Marty's LUT shader 1.0 for ReShade 3.0; Copyright © 2008-2016 Marty McFly.
#ifndef fLUT_TextureName
	#define fLUT_TextureName "lut.png"
#endif
#ifndef fLUT_TileSizeXY
	#define fLUT_TileSizeXY 32
#endif
#ifndef fLUT_TileAmount
	#define fLUT_TileAmount 32
#endif

#include "ReShadeUI.fxh"
#include "ReShade.fxh"

#ifndef CONTRAST_HISTOGRAM_SAMPLE_STRIDE
	#define CONTRAST_HISTOGRAM_SAMPLE_STRIDE 16
#endif

#define PREFIX_SCAN_THREADS 256

#define BIN_COUNT 1024

#define PREFIX_SCAN_BINS_PER_THREAD (BIN_COUNT / PREFIX_SCAN_THREADS)

#define RESOLUTION_MULTIPLIER CONTRAST_HISTOGRAM_SAMPLE_STRIDE

#define SAMPLE_DIMENSIONS uint2((BUFFER_WIDTH / RESOLUTION_MULTIPLIER), \
							    (BUFFER_HEIGHT / RESOLUTION_MULTIPLIER))
					  
#define VERTEX_COUNT uint(SAMPLE_DIMENSIONS.x * SAMPLE_DIMENSIONS.y)




namespace Contrast 
{
	texture BackBuffer : COLOR;
	texture Histogram {Width = BIN_COUNT; Height = 1; Format = R32f;};
	texture texLUT < source = fLUT_TextureName; > { Width = fLUT_TileSizeXY*fLUT_TileAmount; Height = fLUT_TileSizeXY; Format = RGBA8; };

	sampler sBackBuffer {Texture = BackBuffer;};
	sampler sHistogram {Texture = Histogram;};
	sampler SamplerLUT {Texture = texLUT;};
	texture Variances {Width = 3; Height = 1; Format = R32f;};
	texture HistogramLUT {Width = BIN_COUNT; Height = 1; Format = R32f;};
	
	sampler sVariances {Texture = Variances;};
	sampler sHistogramLUT {Texture = HistogramLUT;};

	storage wVariances {Texture = Variances;};
	storage wHistogramLUT {Texture = HistogramLUT;};

	uniform float fLUT_AmountChroma <
		__UNIFORM_SLIDER_FLOAT1
		ui_min = 0.00; ui_max = 1.00;
		ui_label = "LUT chroma amount";
		ui_tooltip = "Intensity of color/chroma change of the LUT.";
		ui_category = "LUT";
	> = 1.00;

	uniform float fLUT_AmountLuma <
		__UNIFORM_SLIDER_FLOAT1
		ui_min = 0.00; ui_max = 1.00;
		ui_label = "LUT luma amount";
		ui_tooltip = "Intensity of luma change of the LUT.";
		ui_category = "LUT";
	> = 1.00;

	uniform float DarkMax<
		ui_type = "slider";
		ui_label = "Dark Strength";
		ui_tooltip = "Sets how strongly the histogram-based adjustment can affect dark tones. Lower values preserve more of the original shadows; higher values apply more of the dark-range stretch. Set to 0 to disable this blending.";
		ui_category = "Contrast";
		ui_min = 0; ui_max = 3;
	> = 0.45;

	uniform float MidMax<
		ui_type = "slider";
		ui_label = "Mid Strength";
		ui_tooltip = "Sets how strongly the histogram-based adjustment can affect middle tones. Lower values keep midtones closer to their original brightness; higher values apply more of the middle-range stretch. Set to 0 to disable this blending.";
		ui_category = "Contrast";
		ui_min = 0; ui_max = 3;
	> = 0.45;

	uniform float LightMax<
		ui_type = "slider";
		ui_label = "Light Strength";
		ui_tooltip = "Sets how strongly the histogram-based adjustment can affect light tones. Lower values preserve more of the original highlights; higher values apply more of the light-range stretch. Set to 0 to disable this blending.";
		ui_category = "Contrast";
		ui_min = 0; ui_max = 3;
	> = 0.3;

	uniform float Minimum<
		ui_type = "slider";
		ui_label = "Minimum";
		ui_tooltip = "Sets the lowest output brightness used when stretching the dark range. Lower values keep shadows darker; higher values lift shadows and can make the image look washed out. Pure black remains unchanged.";
		ui_category = "Thresholds";
		ui_category_closed = true;
		ui_min = 0; ui_max = 1;
	> = 0;


	uniform float DarkThreshold<
		ui_type = "slider";
		ui_label = "Dark Threshold";
		ui_tooltip = "Sets the brightness boundary between the dark and middle ranges. Lower values classify fewer tones as dark; higher values extend the dark-range adjustment into brighter tones.";
		ui_category = "Thresholds";
		ui_min = 0; ui_max = 1;
	> = 0.333;

	uniform float LightThreshold<
		ui_type = "slider";
		ui_label = "LightThreshold";
		ui_tooltip = "Sets the brightness boundary between the middle and light ranges. Lower values start the light-range adjustment at darker tones; higher values reserve it for brighter tones and extend the middle range.";
		ui_category = "Thresholds";
		ui_min = 0; ui_max = 1;
	> = 0.667;

	uniform float Maximum<
		ui_type = "slider";
		ui_label = "Maximum";
		ui_tooltip = "Sets the highest output brightness used when stretching the light range. Lower values compress highlights and make them dimmer; higher values allow brighter highlights. Pure white remains unchanged.";
		ui_category = "Thresholds";
		ui_min = 0; ui_max = 1;
	> = 1;
	
	
	uniform float DarkPeak<
		ui_type = "slider";
		ui_label = "Dark Blending Curve";
		ui_tooltip = "Sets the dark-range variance where its adjustment reaches maximum strength. Lower values place strongest blending at lower variance; higher values move it toward higher variance. The actual strength is controlled by Dark Maximum Blending.";
		ui_category = "Thresholds";
		ui_min = 0; ui_max = 1;
	> = 0.5;
	
	uniform float MidPeak<
		ui_type = "slider";
		ui_label = "Mid Blending Curve";
		ui_tooltip = "Sets the middle-range variance where its adjustment reaches maximum strength. Lower values place strongest blending at lower variance; higher values move it toward higher variance. The actual strength is controlled by Mid Maximum Blending.";
		ui_category = "Thresholds";
		ui_min = 0; ui_max = 1;
	> = 0.55;

	uniform float LightPeak<
		ui_type = "slider";
		ui_label = "Light Blending Curve";
		ui_tooltip = "Sets the light-range variance where its adjustment reaches maximum strength. Lower values place strongest blending at lower variance; higher values move it toward higher variance. The actual strength is controlled by Light Maximum Blending.";
		ui_category = "Thresholds";
		ui_min = 0; ui_max = 1;
	> = 0.45;

	uniform float MaxVariance<
		ui_type = "slider";
		ui_label = "Maximum Curve Value";
		ui_tooltip = "Sets the upper variance used to evaluate all three blending curves. When a curve peak is below this value, its influence falls to zero here. Lower values make blending taper off sooner; higher values allow it across a wider variance range.";
		ui_category = "Maximum Curve Value";
		ui_category_closed = true;
		ui_min = 0.15; ui_max = 1;
	> = 1;
	
	uniform uint Debug<
		ui_type = "combo";
		ui_label = "Debug";
		ui_tooltip = "Selects an inspection view instead of the normal image: Histogram shows sampled brightness counts; Dark, Mid, and Light Curve Input show the measured variance for each range. None disables the debug view.";
		ui_category = "Debug Views";
		ui_category_closed = true;
		ui_items = "None \0Histogram \0Dark Curve Input \0Mid Curve Input \0Light Curve Input \0";
	> = 0;

	uniform float Gamma <
		ui_text = "Filters applied after contrast:";
		ui_type = "slider";
		ui_label = "Gamma";
		ui_tooltip = "Adjust midtones. 1.0 is neutral.";
		ui_category = "Tonemap";
		ui_min = 0.0; ui_max = 2.0;
	> = 1.0;

	uniform float Exposure <
		ui_type = "slider";
		ui_label = "Exposure";
		ui_tooltip = "Adjust exposure.";
		ui_category = "Tonemap";
		ui_min = -1.0; ui_max = 1.0;
	> = 0.0;

	uniform float Saturation <
		ui_type = "slider";
		ui_label = "Saturation";
		ui_tooltip = "Adjust saturation.";
		ui_category = "Tonemap";
		ui_min = -1.0; ui_max = 1.0;
	> = 0.0;

	uniform float Bleach <
		ui_type = "slider";
		ui_label = "Bleach";
		ui_tooltip = "Brightens the shadows and fades the colors.";
		ui_category = "Tonemap";
		ui_min = 0.0; ui_max = 1.0;
	> = 0.0;

	float WeightingCurve(float peak, float variance, float maximumBlending)
	{
		variance = clamp(variance, 0, MaxVariance);
		if(variance <= peak)
		{
			return lerp(0, maximumBlending, abs(variance) / peak);
		}
		else
		{
			return lerp(maximumBlending, 0, abs(variance - peak) / (MaxVariance - peak));
		}
	}

	groupshared float2 PrefixScanTotals[PREFIX_SCAN_THREADS];
	groupshared float2 PrefixScanThresholds[3];
	groupshared float3 PrefixVarianceSums[PREFIX_SCAN_THREADS];

	void PrefixVarianceCS(uint3 groupThreadID : SV_GroupThreadID)
	{
		uint threadIndex = groupThreadID.x;
		uint2 thresholds = round(float2(DarkThreshold, LightThreshold) * (BIN_COUNT - 1));
		float2 localPrefixes[PREFIX_SCAN_BINS_PER_THREAD];
		float localCounts[PREFIX_SCAN_BINS_PER_THREAD];
		float2 localSum = 0;

		[loop]
		for(uint i = 0; i < PREFIX_SCAN_BINS_PER_THREAD; ++i)
		{
			uint bin = threadIndex * PREFIX_SCAN_BINS_PER_THREAD + i;
			float count = tex2Dfetch(sHistogram, float2(bin, 0)).x;
			localCounts[i] = count;
			localSum += float2(count, count * bin);
			localPrefixes[i] = localSum;
		}

		PrefixScanTotals[threadIndex] = localSum;
		barrier();

		[unroll]
		for(uint offset = 1; offset < PREFIX_SCAN_THREADS; offset *= 2)
		{
			float2 previous = threadIndex >= offset ? PrefixScanTotals[threadIndex - offset] : 0;
			barrier();
			PrefixScanTotals[threadIndex] += previous;
			barrier();
		}

		if(threadIndex == 0)
		{
			PrefixScanThresholds[0] = 0;
			PrefixScanThresholds[1] = 0;
			PrefixScanThresholds[2] = PrefixScanTotals[PREFIX_SCAN_THREADS - 1];
		}
		barrier();

		float2 previousBlockSum = threadIndex == 0 ? 0 : PrefixScanTotals[threadIndex - 1];
		[loop]
		for(uint i = 0; i < PREFIX_SCAN_BINS_PER_THREAD; ++i)
		{
			uint bin = threadIndex * PREFIX_SCAN_BINS_PER_THREAD + i;
			float2 prefix = localPrefixes[i] + previousBlockSum;

			if(bin == thresholds.x)
			{
				PrefixScanThresholds[0] = prefix;
			}
			if(bin == thresholds.y)
			{
				PrefixScanThresholds[1] = prefix;
			}
		}
		barrier();

		float2 darkSums = PrefixScanThresholds[0];
		float2 midSums = PrefixScanThresholds[1] - darkSums;
		float2 lightSums = PrefixScanThresholds[2] - PrefixScanThresholds[1];
		float darkMean = darkSums.y / darkSums.x;
		float midMean = midSums.y / midSums.x;
		float lightMean = lightSums.y / lightSums.x;
		float3 localVariance = 0;

		[loop]
		for(uint i = 0; i < PREFIX_SCAN_BINS_PER_THREAD; ++i)
		{
			uint bin = threadIndex * PREFIX_SCAN_BINS_PER_THREAD + i;
			if(bin <= thresholds.x)
			{
				localVariance.x += abs(float(bin) - darkMean) / float(thresholds.x - 1) * (localCounts[i] / darkSums.x);
			}
			else if(bin <= thresholds.y)
			{
				localVariance.y += abs(float(bin) - midMean) / float(thresholds.y - thresholds.x) * (localCounts[i] / midSums.x);
			}
			else
			{
				localVariance.z += abs(float(bin) - lightMean) / float(BIN_COUNT - thresholds.y) * (localCounts[i] / lightSums.x);
			}
		}

		PrefixVarianceSums[threadIndex] = localVariance;
		barrier();

		[unroll]
		for(uint offset = PREFIX_SCAN_THREADS / 2; offset > 0; offset /= 2)
		{
			if(threadIndex < offset)
			{
				PrefixVarianceSums[threadIndex] += PrefixVarianceSums[threadIndex + offset];
			}
			barrier();
		}

		if(threadIndex == 0)
		{
			tex2Dstore(wVariances, int2(0, 0), float4(PrefixVarianceSums[0].x, 0, 0, 0));
			tex2Dstore(wVariances, int2(1, 0), float4(PrefixVarianceSums[0].y, 0, 0, 0));
			tex2Dstore(wVariances, int2(2, 0), float4(PrefixVarianceSums[0].z, 0, 0, 0));
		}

		[loop]
		for(uint i = 0; i < PREFIX_SCAN_BINS_PER_THREAD; ++i)
		{
			uint bin = threadIndex * PREFIX_SCAN_BINS_PER_THREAD + i;
			float prefixSum = localPrefixes[i].x + previousBlockSum.x;
			float input = (float(bin) + 0.5) / float(BIN_COUNT);
			float lut;

			if(bin <= thresholds.x)
			{
				if(prefixSum > 0)
				{
					lut = prefixSum / PrefixScanThresholds[0].x;
					lut = lut * (DarkThreshold - Minimum) + Minimum;
					float alpha = WeightingCurve(DarkPeak, PrefixVarianceSums[0].x, DarkMax);
					lut = lerp(input, lut, alpha);
				}
				else
				{
					lut = input * (DarkThreshold - Minimum) + Minimum;
				}
			}
			else if(bin <= thresholds.y)
			{
				float previousSum = PrefixScanThresholds[0].x;
				float denominator = PrefixScanThresholds[1].x - previousSum;
				if(denominator < 1)
				{
					lut = input * (LightThreshold - DarkThreshold) + DarkThreshold;
				}
				else
				{
					lut = (prefixSum - previousSum) / denominator;
					lut = lut * (LightThreshold - DarkThreshold) + DarkThreshold;
					float alpha = WeightingCurve(MidPeak, PrefixVarianceSums[0].y, MidMax);
					lut = lerp(input, lut, alpha);
				}
			}
			else
			{
				float previousSum = PrefixScanThresholds[1].x;
				float denominator = PrefixScanThresholds[2].x - previousSum;
				if(denominator < 1)
				{
					lut = input * (Maximum - LightThreshold) + LightThreshold;
				}
				else
				{
					lut = (prefixSum - previousSum) / denominator;
					lut = lut * (Maximum - LightThreshold) + LightThreshold;
					float alpha = WeightingCurve(LightPeak, PrefixVarianceSums[0].z, LightMax);
					lut = lerp(input, lut, alpha);
				}
			}

			tex2Dstore(wHistogramLUT, int2(bin, 0), float4(lut, 0, 0, 0));
		}
	}

	// Vertex shader generating a triangle covering the entire screen
	void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
	{
		texcoord.x = (id == 2) ? 2.0 : 0.0;
		texcoord.y = (id == 1) ? 2.0 : 0.0;
		position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
	}

	float3 ApplyLUT(float3 color)
	{
		float2 texelsize = 1.0 / fLUT_TileSizeXY;
		texelsize.x /= fLUT_TileAmount;

		float3 lutcoord = float3((color.xy * fLUT_TileSizeXY - color.xy + 0.5) * texelsize.xy, color.z * fLUT_TileSizeXY - color.z);
		float lerpfact = frac(lutcoord.z);
		lutcoord.x += (lutcoord.z - lerpfact) * texelsize.y;

		float3 lutcolor = lerp(
			tex2Dlod(SamplerLUT, float4(lutcoord.xy, 0, 0)).xyz,
			tex2Dlod(SamplerLUT, float4(lutcoord.x + texelsize.y, lutcoord.y, 0, 0)).xyz,
			lerpfact);

		return lerp(normalize(color), normalize(lutcolor), fLUT_AmountChroma) *
			lerp(length(color), length(lutcolor), fLUT_AmountLuma);
	}

	void HistogramVS(in uint id : SV_VertexID, out float4 pos : SV_Position)
	{
		float2 coord = floor(float2(id % SAMPLE_DIMENSIONS.x, id / SAMPLE_DIMENSIONS.x)) * RESOLUTION_MULTIPLIER + 0.5;
		float3 color = ApplyLUT(tex2Dfetch(sBackBuffer, coord).rgb);
		float luma = (round(dot(color, float3(0.299, 0.587, 0.114)) * (BIN_COUNT - 1)) + 0.5) / float(BIN_COUNT);
		
		pos.x = luma * 2 - 1;
		pos.y = 0;
		pos.z = 0;
		pos.w = 1;
	}
	
	void HistogramPS(float4 pos : SV_Position, out float add : SV_Target0)
	{
		add = 1;
	}

	float3 ApplyTonemap(float3 color)
	{
		color = saturate(color);
		color *= pow(2.0, Exposure);
		color = pow(color, Gamma);

		const float3 coefLuma = float3(0.2126, 0.7152, 0.0722);
		float lum = dot(coefLuma, color);

		float L = saturate(10.0 * (lum - 0.45));
		float3 A2 = Bleach * color;

		float3 result1 = 2.0 * color * lum;
		float3 result2 = 1.0 - 2.0 * (1.0 - lum) * (1.0 - color);

		float3 newColor = lerp(result1, result2, L);
		float3 mixRGB = A2 * newColor;
		color += ((1.0 - A2) * mixRGB);

		float middlegray = dot(color, (1.0 / 3.0));
		float3 diffcolor = color - middlegray;
		color = (color + diffcolor * Saturation) / (1 + (diffcolor * Saturation));

		return color;
	}
	
	void OutputPS(float4 pos : SV_Position, float2 texcoord : TEXCOORD, out float3 color : SV_Target0)
	{
		color = ApplyLUT(tex2D(sBackBuffer, texcoord).rgb);
		if(!all(color == 0.0) && !all(color == 1.0))
		{
			float yOld = dot(color, float3(0.299, 0.587, 0.114));
			float y = tex2D(sHistogramLUT, float2(yOld, 0.5)).x;

			float cb = -0.168736 * color.r - 0.331264 * color.g + 0.500000 * color.b;
			float cr = +0.500000 * color.r - 0.418688 * color.g - 0.081312 * color.b;

			color = float3(
					y + 1.402 * cr,
					y - 0.344136 * cb - 0.714136 * cr,
					y + 1.772 * cb);
		}

		if(Gamma != 1.0 || Exposure != 0.0 || Saturation != 0.0 || Bleach != 0.0)
		{
			color = ApplyTonemap(color);
		}
				
		if(Debug == 1)
		{
			texcoord = float2(3 * texcoord.x - 2, 1 - texcoord.y);
			uint2 coord = uint2(round(texcoord * float2((BIN_COUNT - 1), BUFFER_HEIGHT * (65536 / (BIN_COUNT * RESOLUTION_MULTIPLIER * 0.5 * RESOLUTION_MULTIPLIER)))));
			if(texcoord.x >= 0)
			{
				uint histogramBin = tex2D(sHistogram, float2(texcoord.x, 0.5)).x;
				if(coord.y <= histogramBin)
				{
					color = lerp(color, 1 - color, 0.7);
				}
			}
		}
		else if(Debug == 2)
		{
			texcoord = float2(1 - texcoord.x, texcoord.y * (float(BUFFER_HEIGHT) / float(BUFFER_WIDTH)));
			if(all(texcoord <= 0.125))
			{
				color = tex2Dfetch(sVariances, float2(0, 0)).xxx;
			}
		}
		else if(Debug == 3)
		{
			texcoord = float2(1 - texcoord.x, texcoord.y * (float(BUFFER_HEIGHT) / float(BUFFER_WIDTH)));
			if(all(texcoord <= 0.125))
			{
				color = tex2Dfetch(sVariances, float2(1, 0)).xxx;
			}
		}
		else if(Debug == 4)
		{
			texcoord = float2(1 - texcoord.x, texcoord.y * (float(BUFFER_HEIGHT) / float(BUFFER_WIDTH)));
			if(all(texcoord <= 0.125))
			{
				color = tex2Dfetch(sVariances, float2(2, 0)).xxx;
			}
		}
	}

	technique LUTContrastStretch<ui_tooltip = "A histogram based contrast stretching shader that\n"
										   "adaptively adjusts the contrast of the image\n"
										   "based on its contents.\n\n"
										   "Part of Insane Shaders \n"
										   "By: Lord Of Lunacy\n\n"
										   "Optimized By: Snoggles\n\n"
										   "CONTRAST_HISTOGRAM_SAMPLE_STRIDE trades performance and quality.";>
	{
		pass Histogram
		{
			VertexShader = HistogramVS;
			PixelShader = HistogramPS;
			RenderTarget0 = Histogram;
			PrimitiveTopology = POINTLIST;
			VertexCount = VERTEX_COUNT;
			ClearRenderTargets = true;
			BlendEnable = true;
			BlendOp = ADD;
			SrcBlend = ONE;
			DestBlend = ONE;
		}
		
		pass PrefixVariance
		{
			ComputeShader = PrefixVarianceCS<PREFIX_SCAN_THREADS, 1, 1>;
			DispatchSizeX = 1;
			DispatchSizeY = 1;
		}
		
		pass Output
		{
			VertexShader = PostProcessVS;
			PixelShader = OutputPS;
		}
	}
}
