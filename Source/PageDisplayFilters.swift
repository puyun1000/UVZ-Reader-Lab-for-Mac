import AppKit
import CoreImage

struct PageDisplayOptions {
    var automatic = false
    var brightness = 0.0
    var contrast = 1.0
    var gamma = 1.0
    var warm = false
    var active: Bool { automatic || brightness != 0 || contrast != 1 || gamma != 1 || warm }
    var key: String { "\(automatic):\(brightness):\(contrast):\(gamma):\(warm)" }
}

enum PageDisplayFilters {
    private static let context = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!, .outputColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!])
    /// A bounded color sample avoids stretching photographs as if they were faded text.
    static func blackWhiteRange(_ image: CGImage) -> (Double,Double)? {
        let width=192,height=max(1,Int(Double(image.height)*192/Double(image.width)))
        guard height<=4096 else{return nil}
        var pixels=[UInt8](repeating:255,count:width*height*4)
        let ok=pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let c=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{return false}
            c.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard ok else{return nil}
        var histogram=[Int](repeating:0,count:256),colored=0
        for i in stride(from:0,to:pixels.count,by:4) {
            let r=Int(pixels[i]),g=Int(pixels[i+1]),b=Int(pixels[i+2])
            if max(r,g,b)-min(r,g,b)>25 {colored+=1}
            histogram[(r*77+g*150+b*29)>>8]+=1
        }
        let count=width*height
        guard colored<count/40 else{return nil}
        func percentile(_ threshold:Int)->Int {
            var sum=0
            for i in 0..<256 {sum+=histogram[i];if sum>=threshold{return i}}
            return 255
        }
        let low=percentile(max(1,count/200)),high=percentile(max(1,count*99/100))
        guard high-low>=15,high>150 else{return nil}
        return (Double(low)/255,Double(high)/255)
    }

    static func render(_ image: CGImage,options: PageDisplayOptions,range: (Double,Double)? = nil,invert:Bool = false) throws -> CGImage {
        guard options.active || invert else{return image}
        var value=CIImage(cgImage:image)
        if options.automatic,let (low,high)=range ?? blackWhiteRange(image) {
            let scale=1/(high-low),bias = -low*scale
            value=value.applyingFilter("CIColorMatrix",parameters:[
                "inputRVector":CIVector(x:scale,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:scale,z:0,w:0),
                "inputBVector":CIVector(x:0,y:0,z:scale,w:0),"inputBiasVector":CIVector(x:bias,y:bias,z:bias,w:0)])
        }
        value=value.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:options.brightness,kCIInputContrastKey:options.contrast])
        value=value.applyingFilter("CIGammaAdjust",parameters:["inputPower":options.gamma])
        if options.warm {
            value=value.applyingFilter("CIColorMatrix",parameters:[
                "inputRVector":CIVector(x:172.0/255,y:0,z:0,w:0),
                "inputGVector":CIVector(x:0,y:177.0/255,z:0,w:0),
                "inputBVector":CIVector(x:0,y:0,z:164.0/255,w:0),
                "inputBiasVector":CIVector(x:73.0/255,y:55.0/255,z:40.0/255,w:0)])
        }
        if invert {value=value.applyingFilter("CIColorInvert")}
        guard let output=context.createCGImage(value,from:value.extent) else{throw ReaderFailure("页面显示调整失败。")}
        return output
    }
}
