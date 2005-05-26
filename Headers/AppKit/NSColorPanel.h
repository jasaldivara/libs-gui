/* 
   NSColorPanel.h

   System generic color panel

   Copyright (C) 1996 Free Software Foundation, Inc.

   Author:  Scott Christley <scottc@net-community.com>
   Date: 1996
   
   This file is part of the GNUstep GUI Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Library General Public
   License along with this library; see the file COPYING.LIB.
   If not, write to the Free Software Foundation,
   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
*/ 

#ifndef _GNUstep_H_NSColorPanel
#define _GNUstep_H_NSColorPanel

#include <AppKit/NSApplication.h>
#include <AppKit/NSBox.h>
#include <AppKit/NSButton.h>
#include <AppKit/NSColorPicking.h>
#include <AppKit/NSColorWell.h>
#include <AppKit/NSMatrix.h>
#include <AppKit/NSNibDeclarations.h>
#include <AppKit/NSPanel.h>
#include <AppKit/NSSlider.h>
#include <AppKit/NSSplitView.h>

@class NSView;
@class NSColorList;
@class NSEvent;

enum {
  NSGrayModeColorPanel,
  NSRGBModeColorPanel,
  NSCMYKModeColorPanel,
  NSHSBModeColorPanel,
  NSCustomPaletteModeColorPanel,
  NSColorListModeColorPanel,
  NSWheelModeColorPanel 
};

enum {
  NSColorPanelGrayModeMask = 1,
  NSColorPanelRGBModeMask = 2,
  NSColorPanelCMYKModeMask = 4,
  NSColorPanelHSBModeMask = 8,
  NSColorPanelCustomPaletteModeMask = 16,
  NSColorPanelColorListModeMask = 32,
  NSColorPanelWheelModeMask = 64,
  NSColorPanelAllModesMask = 127 
};

@interface NSApplication (NSColorPanel)
- (void) orderFrontColorPanel: (id)sender;
@end

@interface NSColorPanel : NSPanel
{
  // Attributes
  NSView		*_topView;
  NSColorWell		*_colorWell;
  NSButton		*_magnifyButton;
  NSMatrix		*_pickerMatrix;
  NSBox			*_pickerBox;
  NSSlider		*_alphaSlider;
  NSSplitView		*_splitView;
  NSView		*_accessoryView;

  //NSMatrix		*_swatches;

  NSMutableArray	*_pickers;
  id<NSColorPickingCustom,NSColorPickingDefault> _currentPicker;
  id			_target;
  SEL			_action;
  BOOL			_isContinuous;
  BOOL                  _showsAlpha;
}

//
// Creating the NSColorPanel 
//
+ (NSColorPanel *)sharedColorPanel;
+ (BOOL)sharedColorPanelExists;

//
// Setting the NSColorPanel 
//
+ (void)setPickerMask:(int)mask;
+ (void)setPickerMode:(int)mode;
- (NSView *)accessoryView;
- (BOOL)isContinuous;
- (int)mode;
- (void)setAccessoryView:(NSView *)aView;
- (void)setAction:(SEL)aSelector;
- (void)setContinuous:(BOOL)flag;
- (void)setMode:(int)mode;
- (void)setShowsAlpha:(BOOL)flag;
- (void)setTarget:(id)anObject;
- (BOOL)showsAlpha;

//
// Attaching a Color List
//
- (void)attachColorList:(NSColorList *)aColorList;
- (void)detachColorList:(NSColorList *)aColorList;

//
// Setting Color
//
+ (BOOL)dragColor:(NSColor *)aColor
	withEvent:(NSEvent *)anEvent
	 fromView:(NSView *)sourceView;
- (void)setColor:(NSColor *)aColor;

- (float)alpha;
- (NSColor *)color;

@end

/* Notifications */
APPKIT_EXPORT NSString *NSColorPanelColorChangedNotification;

#endif // _GNUstep_H_NSColorPanel
