/*
   NSLayoutManager.h

   Copyright (C) 2002 Free Software Foundation, Inc.

   Author: Alexander Malmberg <alexander@malmberg.org>
   Date: 2002-11

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

#ifndef _GNUstep_H_NSLayoutManager
#define _GNUstep_H_NSLayoutManager

#include <GNUstepGUI/GSLayoutManager.h>
#include <AppKit/NSTextView.h>

@class NSParagraphStyle;


/*
GNUstep extension.
*/
typedef enum {
  GSInsertionPointMoveLeft,
  GSInsertionPointMoveRight,
  GSInsertionPointMoveDown,
  GSInsertionPointMoveUp,
} GSInsertionPointMovementDirection;


@interface NSLayoutManager : GSLayoutManager
{
  /* Public for use only in the associated NSTextViews.  Don't access
     them directly from elsewhere. */
@public 
  /* Ivars to synchronize multiple textviews */
  BOOL _isSynchronizingFlags;
  BOOL _isSynchronizingDelegates;
  BOOL _beganEditing;

  /* Selection */
  NSRange _selected_range;
  NSRange _original_selected_range;
  NSSelectionGranularity _selectionGranularity;
  NSSelectionAffinity _selectionAffinity;

  /* Retained by the NSLayoutManager. NSTextView:s that change this value
  should release the old value and retain the new one. It is nil originally
  and will be released when the NSLayoutManager is deallocated. */
  NSMutableDictionary *_typingAttributes;
}

/* TODO */

-(void) invalidateDisplayForGlyphRange: (NSRange)aRange;
-(void) invalidateDisplayForCharacterRange: (NSRange)aRange; /* not STRICT_40 ?? */

- (NSTextView *) firstTextView;
- (NSTextView *) textViewForBeginningOfSelection;
- (BOOL) layoutManagerOwnsFirstResponderInWindow: (NSWindow *)window;

-(NSArray *) rulerMarkersForTextView: (NSTextView *)textView
		      paragraphStyle: (NSParagraphStyle *)paragraphStyle
			       ruler: (NSRulerView *)aRulerView;
-(NSView *) rulerAccessoryViewForTextView: (NSTextView *)textView
			   paragraphStyle: (NSParagraphStyle *)style
				    ruler: (NSRulerView *)ruler
				  enabled: (BOOL)isEnabled;

-(float) hyphenationFactor;
-(void) setHyphenationFactor: (float)factor;

@end


@interface NSLayoutManager (layout)

- (void) textContainerChangedTextView: (NSTextContainer *)aContainer;


- (NSPoint) locationForGlyphAtIndex: (unsigned int)glyphIndex;


- (NSRect *) rectArrayForGlyphRange: (NSRange)glyphRange
	withinSelectedGlyphRange: (NSRange)selGlyphRange
	inTextContainer: (NSTextContainer *)container
	rectCount: (unsigned int *)rectCount;
- (NSRect *) rectArrayForCharacterRange: (NSRange)charRange
	withinSelectedCharacterRange: (NSRange)selCharRange
	inTextContainer: (NSTextContainer *)container
	rectCount: (unsigned int *)rectCount;

- (NSRect) boundingRectForGlyphRange: (NSRange)glyphRange 
	inTextContainer: (NSTextContainer *)aTextContainer;


- (NSRange) glyphRangeForBoundingRect: (NSRect)bounds 
	inTextContainer: (NSTextContainer *)container;
- (NSRange) glyphRangeForBoundingRectWithoutAdditionalLayout: (NSRect)bounds
	inTextContainer: (NSTextContainer *)container;

- (unsigned int) glyphIndexForPoint: (NSPoint)aPoint
	inTextContainer: (NSTextContainer *)aTextContainer;
- (unsigned int) glyphIndexForPoint: (NSPoint)point
	inTextContainer: (NSTextContainer *)container
	fractionOfDistanceThroughGlyph: (float *)partialFraction;


/*
Returns a rectangle suitable for drawing an insertion point in if the
insertion point is placed before the given character. The character index
may be any character in the text (it will handle positions "inside" a
ligature), and (unlike other methods) it may be one past the end of the
text (ie. cindex==[[_textStorage string] length]).

If the character isn't in the text container, returns NSZeroRect.

GNUstep extension.
*/
-(NSRect) insertionPointRectForCharacterIndex: (unsigned int)cindex
			      inTextContainer: (NSTextContainer *)textContainer;


/*
Insertion point movement primitive. 'from' is the character index moved from,
and 'original' is the character index originally moved from in this sequence
of moves (ie. if the user hits the down key several times, the first call
would have original==from, and subsequent calls would use the same 'original'
and the 'from' returned from the last call).

The returned character index will always be different from 'from' unless
'from' is the "furthest" character index in the text container in the
specified direction.

The distance is the target distance for the move (in the text container's
coordinate system). The move won't be farther than this distance unless
it's impossible to move a shorter distance. Distance 0.0 is treated
specially: the move will be the shortest possible move, and movement will
"make sense" even if the glyph/character mapping is complex at 'from'
(eg. it will move through ligatures in a sensible way).

Note that this method does not work across text containers. 'original' and
'from' should be in the same container, and the returned index will also be
in that container.

GNUstep extension.
*/
-(unsigned int) characterIndexMoving: (GSInsertionPointMovementDirection)direction
		  fromCharacterIndex: (unsigned int)from
	      originalCharacterIndex: (unsigned int)original
			    distance: (float)distance;

@end


@interface NSLayoutManager (drawing)

-(void) drawBackgroundForGlyphRange: (NSRange)range
	atPoint: (NSPoint)containerOrigin;

-(void) drawGlyphsForGlyphRange: (NSRange)range
	atPoint: (NSPoint)containerOrigin;

/* TODO: underline */

@end


#endif

