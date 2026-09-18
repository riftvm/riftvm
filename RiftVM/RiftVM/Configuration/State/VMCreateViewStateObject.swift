//
//  CreateFormModel.swift
//  RiftVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI
import Observation

#if arch(arm64)
/// Form state for the one preparation flow RiftVM has: a signed Omarchy
/// factory image. There is no image picker, so nothing here describes a
/// system other than Omarchy.
@MainActor
@Observable
class VMCreateViewStateObject {

    struct LogModel : Identifiable {
        let id = UUID()
        let time: String
        let log: String
        
        init(_ log: String) {
            let date = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm:ss"
            self.time = dateFormatter.string(from: date)
            
            self.log = log
        }
    }
    
    
    // phase
    var rootPath: String = ""
    var baseDirectory: String = ""
    var hasGeneratedNameSuggestion = false

    var logs: [LogModel] = []

    var installingProgress: Double = 0.0
    var downloadBytesReceived: Int64?
    var downloadBytesExpected: Int64?

    var disablePreviousButton = false

    // creating phase status
    var isCreating = false
    var canCancelCreation = false
    var creationCancellationKind: VMCreationCancellationKind?
    var statusText: String = ""
    var creationStage: String = "Preparing"


    init() {
    }

    func addLog(_ log: String) {
        logs.insert(LogModel(log), at: 0)
        statusText = log
    }
    
    func changeProgress(_ percent: Double) {
        if percent > 1.0 {
            return
        }
        if percent < 0.0 {
            return
        }
        installingProgress = percent
    }
    
}


#endif
