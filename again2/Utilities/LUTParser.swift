import Foundation
import CoreImage

struct LUTParser {
    
    // Parse a .cube file and return data suitable for CIColorCube
    static func parseCubeFile(at url: URL) throws -> (data: Data, dimension: Int) {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        
        var lutSize = 0
        var rgbValues: [Float] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            // Parse LUT size
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let components = trimmed.components(separatedBy: .whitespaces)
                if components.count >= 2, let size = Int(components[1]) {
                    lutSize = size
                }
                continue
            }
            
            // Skip metadata lines
            if trimmed.hasPrefix("TITLE") || trimmed.hasPrefix("DOMAIN_MIN") || trimmed.hasPrefix("DOMAIN_MAX") {
                continue
            }
            
            // Parse RGB values
            let components = trimmed.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            
            if components.count >= 3,
               let r = Float(components[0]),
               let g = Float(components[1]),
               let b = Float(components[2]) {
                rgbValues.append(r)
                rgbValues.append(g)
                rgbValues.append(b)
                // CIColorCube expects RGBA, so add alpha channel
                rgbValues.append(1.0)
            }
        }
        
        guard lutSize > 0 else {
            throw LUTError.invalidFormat("LUT_3D_SIZE not found")
        }
        
        let expectedCount = lutSize * lutSize * lutSize * 4 // RGBA
        guard rgbValues.count == expectedCount else {
            throw LUTError.invalidFormat("Expected \(expectedCount) values, got \(rgbValues.count)")
        }
        
        // Convert to Data
        let data = Data(bytes: rgbValues, count: rgbValues.count * MemoryLayout<Float>.size)
        
        return (data, lutSize)
    }
    
    // Create a CIFilter from a .cube file
    static func createColorCubeFilter(from cubeURL: URL) throws -> CIFilter {
        let (lutData, dimension) = try parseCubeFile(at: cubeURL)
        
        guard let filter = CIFilter(name: "CIColorCube") else {
            throw LUTError.filterCreationFailed
        }
        
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(lutData, forKey: "inputCubeData")
        
        return filter
    }
}

enum LUTError: Error, LocalizedError {
    case invalidFormat(String)
    case filterCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidFormat(let message):
            return "Invalid LUT format: \(message)"
        case .filterCreationFailed:
            return "Failed to create color cube filter"
        }
    }
}

