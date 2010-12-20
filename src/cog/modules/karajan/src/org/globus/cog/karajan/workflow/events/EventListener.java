
// ----------------------------------------------------------------------
// This code is developed as part of the Java CoG Kit project
// The terms of the license can be found at http://www.cogkit.org/license
// This message may not be removed or altered.
// ----------------------------------------------------------------------

package org.globus.cog.karajan.workflow.events;

import org.globus.cog.karajan.workflow.ExecutionException;


public interface EventListener {
	void event(Event e) throws ExecutionException;
}