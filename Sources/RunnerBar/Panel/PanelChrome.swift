// PanelChrome.swift
// RunnerBar
// This file has been intentionally emptied as part of fix/#1017.
// PanelChromeView and the CAShapeLayer arrow/mask approach have been removed.
// Native NSPanel rounded corners (window-server level) are used instead.
// ❌ NEVER restore PanelChromeView — it causes rectangular corners on the
// parent panel whenever a SwiftUI .sheet is presented (AppKit sheet attachment
// invalidates CAShapeLayer masks on the parent window's layer tree).
// See: https://github.com/eoncode/runner-bar/issues/1017
