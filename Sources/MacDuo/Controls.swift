import SwiftUI
import MetalKit
import FoldCore

struct MetalPreview: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = model.device else { return view }
        do {
            let renderer = try FoldRenderer(device:device)
            renderer.fallback = try renderer.makePreviewTexture()
            renderer.parameters = { [weak model] in model?.uniforms(preview:true) ?? FoldUniforms() }
            renderer.animatedProgress = { [weak model] in model?.animatedProgress(preview:true) }
            renderer.pausesWhenSettled = true
            renderer.keepsAnimating = { [weak model] in
                guard let model else { return false }
                return model.previewPlaying || (model.followLid && model.demoRunning)
            }
            renderer.onFailure = { [weak model] message in model?.setStatus(message) }
            renderer.configure(view)
            context.coordinator.renderer = renderer
            model.previewRenderer = renderer
            model.previewView = view
        } catch { model.setStatus(error.localizedDescription) }
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = min(60,model.fps)
        context.coordinator.renderer?.wake(view)
    }
    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) { view.isPaused = true;view.delegate = nil }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: FoldRenderer? }
}

struct Controls: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? Color(red:1.0,green:0.56,blue:0.18) : Color(red:0.76,green:0.30,blue:0.04)
    }
    private var background: Color {
        colorScheme == .dark ? Color(red:0.075,green:0.085,blue:0.095) : Color(red:0.97,green:0.965,blue:0.95)
    }

    var body: some View {
        GeometryReader { geometry in
            // All controls stay in one view. Only unusually small display work
            // areas scale the complete layout down; there is no internal scroll.
            let scale = min(1,geometry.size.width/900,geometry.size.height/508)
            let width = geometry.size.width/max(scale,0.1)
            let height = geometry.size.height/max(scale,0.1)
            let previewWidth = max(240,min(480,width-424,(height-205)*1.54+14))
            let panelHeight = (previewWidth-14)/1.54+21
            VStack(alignment:.leading,spacing:14) {
                header
                HStack(alignment:.top,spacing:24) {
                    preview(width:previewWidth).frame(maxWidth:.infinity)
                    settings.frame(width:350,height:panelHeight)
                }
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                footer
            }
            .padding(20)
            .frame(width:width,height:height,alignment:.top)
            .scaleEffect(scale,anchor:.topLeading)
        }
        .background(background)
        .tint(accent)
    }

    private var header: some View {
        HStack(alignment:.top) {
            Image(nsImage:AppBrand.mark).resizable().scaledToFit().frame(width:40,height:40)
                .accessibilityHidden(true)
            VStack(alignment:.leading,spacing:5) {
                Text("Mac Duo").font(.system(size:27,weight:.semibold,design:.rounded))
                Text(model.text("Let your desktop follow the fold.")).font(.system(size:12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing:6) {
                Circle().fill(model.sensorAvailable ? accent : .orange).frame(width:6,height:6)
                Text(model.lidAngle.map { model.format("Lid %.0f°",$0) } ?? model.text("Looking for sensor"))
                    .font(.system(size:12,weight:.medium,design:.monospaced))
            }.padding(.horizontal,12).padding(.vertical,8).background(.primary.opacity(0.055),in:Capsule())
            Menu {
                Picker(model.text("Appearance"),selection:$model.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.localizedTitle(model.language),systemImage:appearance.symbol).tag(appearance)
                    }
                }
            } label: {
                Image(systemName:model.appearance.symbol).font(.system(size:16)).frame(width:28,height:28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(model.text("Appearance"))
            .help(model.format("Appearance: %@",model.appearance.localizedTitle(model.language)))
            Menu {
                Picker(model.text("Language"),selection:$model.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } label: {
                HStack(spacing:4) {
                    Image(systemName:"globe")
                    Text(model.language.shortName).font(.system(size:11,weight:.semibold))
                }.frame(height:28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(model.text("Language"))
        }
    }

    private func preview(width: CGFloat) -> some View {
            VStack(spacing:0) {
                MetalPreview(model:model)
                    .frame(width:width-14,height:(width-14)/1.54)
                    .overlay(alignment:.top) {
                        UnevenRoundedRectangle(bottomLeadingRadius:5,bottomTrailingRadius:5)
                            .fill(.black).frame(width:width*0.16,height:9)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius:12,bottomLeadingRadius:2,bottomTrailingRadius:2,topTrailingRadius:12))
                    .padding(7).background(.black,in:UnevenRoundedRectangle(topLeadingRadius:18,topTrailingRadius:18))
                RoundedRectangle(cornerRadius:3).fill(Color(white:0.34)).frame(height:7).padding(.horizontal,-5)
            }
        .frame(width:width)
    }

    /// Sits in the row the "Controls" heading used to occupy. The reduced stack
    /// spacing keeps the panel exactly as tall as before, so nothing scrolls and
    /// the MacBook and the panel still align at top and bottom.
    private var effectPicker: some View {
        Picker(model.text("Effect"),selection:$model.effect) {
            ForEach(FoldEffect.allCases) { effect in Text(effect.localizedTitle(model.language)).tag(effect) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .font(.system(size:11,weight:.medium))
        .frame(height:19)
        .accessibilityLabel(model.text("Effect"))
        .help(model.format("Effect: %@ — %@",model.effect.localizedTitle(model.language),model.effect.localizedSummary(model.language)))
    }

    private var settings: some View {
        VStack(alignment:.leading,spacing:10) {
            effectPicker
            Toggle(model.text("Follow my lid"),isOn:$model.followLid)
                .toggleStyle(.switch).controlSize(.small).font(.system(size:11.5,weight:.medium))
            slider(model.text("Preview angle"),value:Binding(get:{model.followLid ? model.lidAngle ?? model.clearAngle : model.previewAngle},
                                               set:{model.previewAngle = $0}),range:5...140,
                   text:String(format:"%.0f°",model.followLid ? model.lidAngle ?? 0 : model.previewAngle))
                .disabled(model.followLid || model.previewPlaying)
            Divider()
            slider(model.text("Clears at"),value:$model.clearAngle,range:60...140,text:String(format:"%.0f°",model.clearAngle))
            VStack(alignment:.leading,spacing:6) {
                Toggle(model.text("Clear when the lid is still"),isOn:$model.clearWhenStill)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size:11.5,weight:.medium))
                slider(model.text("Clear after"),value:$model.stillnessDelay,range:1...5,text:String(format:model.language == .simplifiedChinese ? "%.0f 秒" : "%.0f s",model.stillnessDelay),step:1)
                    .disabled(!model.clearWhenStill)
                Text(model.text("Move the lid to bring back the effect."))
                    .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Divider()
            slider(model.text("Perspective"),value:$model.perspective,range:0...1,text:percent(model.perspective))
            slider(model.text("Softness"),value:$model.blur,range:0...1,text:percent(model.blur))
            slider(model.text("Shadow"),value:$model.shadow,range:0...1,text:percent(model.shadow))
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        .padding(16).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:16))
    }

    private var footer: some View {
        VStack(alignment:.leading,spacing:8) {
            Divider()
            HStack(spacing:8) {
                Button(model.text(model.checkingPermission ? "Checking…" : (model.enabled ? "Pause Mac Duo" : "Enable Mac Duo"))) {
                    if model.enabled { model.pause() } else { model.enable() }
                }.disabled(model.checkingPermission).buttonStyle(.borderedProminent).tint(accent)
                Button(model.text(model.demoRunning ? "Testing…" : "Test desktop · 8 sec")) { model.testDesktop() }
                    .disabled(model.demoRunning || model.checkingPermission)
                Button { model.playPreview() } label: { Image(systemName:"play.fill");Text(model.text("Replay")) }
                    .disabled(model.previewPlaying)
                Text(model.status).font(.system(size:11)).foregroundStyle(.secondary)
                    .lineLimit(2).help(model.status).frame(maxWidth:.infinity,alignment:.trailing)
                if !model.hasPermission {
                    Button { model.openPrivacy() } label:{Image(systemName:"gearshape")}.help(model.text("Open Screen Recording settings"))
                }
            }
            HStack(spacing:5) {
                Text(model.text(model.previewPlaying ? "Replaying" : (model.followLid ? "Live preview" : "Manual preview")))
                Text("·")
                Image(systemName:"escape");Text(model.text("to pause"));Text("·");Text("⌃⌥⌘F \(model.text("anywhere"))")
                Spacer()
                if model.reducedMotion { Text(model.text("Reduce Motion on"));Text("·") }
                Text(model.text("On your Mac only")).foregroundStyle(accent.opacity(0.85))
            }.font(.system(size:10)).foregroundStyle(.secondary)
        }
    }

    private func percent(_ x: Double) -> String { String(format:"%.0f%%",x*100) }
    private func slider(_ name:String,value:Binding<Double>,range:ClosedRange<Double>,text:String,step:Double? = nil) -> some View {
        HStack(spacing:10) {
            Text(name).font(.system(size:11.5,weight:.medium)).frame(width:84,alignment:.leading)
            Group {
                if let step { Slider(value:value,in:range,step:step) }
                else { Slider(value:value,in:range) }
            }.accessibilityLabel(name)
            Text(text).font(.system(size:11.5,design:.monospaced)).foregroundStyle(.secondary).frame(width:36,alignment:.trailing)
        }
    }
}
