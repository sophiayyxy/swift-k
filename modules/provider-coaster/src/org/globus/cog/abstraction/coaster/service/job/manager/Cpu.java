//----------------------------------------------------------------------
//This code is developed as part of the Java CoG Kit project
//The terms of the license can be found at http://www.cogkit.org/license
//This message may not be removed or altered.
//----------------------------------------------------------------------

/*
 * Created on Apr 21, 2009
 */
package org.globus.cog.abstraction.coaster.service.job.manager;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedList;
import java.util.List;

import org.apache.log4j.Logger;
import org.globus.cog.abstraction.coaster.service.CoasterService;
import org.globus.cog.abstraction.impl.common.StatusEvent;
import org.globus.cog.abstraction.impl.execution.coaster.SubmitJobCommand;
import org.globus.cog.abstraction.interfaces.Status;
import org.globus.cog.abstraction.interfaces.StatusListener;
import org.globus.cog.abstraction.interfaces.Task;
import org.globus.cog.karajan.workflow.service.channels.ChannelManager;
import org.globus.cog.karajan.workflow.service.channels.KarajanChannel;
import org.globus.cog.karajan.workflow.service.commands.Command;
import org.globus.cog.karajan.workflow.service.commands.Command.Callback;

public class Cpu implements Comparable<Cpu>, Callback, StatusListener {
    public static final Logger logger = Logger.getLogger(Cpu.class);

    private static PullThread pullThread;

    private int id;
    private List<Job> done;
    private Job running;
    private Node node;
    private Time starttime, endtime, timelast, donetime;
    private int lastseq;
    protected long busyTime, idleTime, lastTime;

    public Cpu() {
        this.done = new ArrayList<Job>();
        this.timelast = Time.fromMilliseconds(0);
    }

    public Cpu(int id, Node node) {
        this();
        this.id = id;
        this.node = node;
        timelast = Time.fromSeconds(0);
    }

    public void workerStarted() {
        node.getBlock().remove(this);
        starttime = Time.now();
        endtime = starttime.add(node.getBlock().getWalltime());
        timelast = starttime;
        timeDiff();
        pullLater();
    }

    private long timeDiff() {
        long now = System.currentTimeMillis();
        long dif = now - lastTime;
        lastTime = now;
        return dif;
    }

    public synchronized void jobTerminated() {
        Block block = node.getBlock();
        if (logger.isInfoEnabled()) {
            logger.info(block.getId() + ":" + getId() + " jobTerminated");
        }
        block.increaseDoneJobCount();
        block.remove(this);
        donetime = Time.now();
        timelast = donetime;
        busyTime += timeDiff();
        // done.add(running);
        running = null;
        if (!checkSuspended(block)) {
            pullLater();
        }
    }

    private void pullLater() {
        pullLater(this);
    }

    private void sleep() {
        sleep(this);
    }

    private static PullThread getPullThread(Block block) {
        if (pullThread == null) {
            pullThread = new PullThread(block.getAllocationProcessor());
            pullThread.start();
        }
        return pullThread;
    }

    private static synchronized void pullLater(Cpu cpu) {
        Block block = cpu.node.getBlock();
        if (logger.isDebugEnabled()) {
            logger.debug(block.getId() + ":" + cpu.getId() + " pullLater");
        }
        getPullThread(block).enqueue(cpu);
    }

    private synchronized void sleep(Cpu cpu) {
        getPullThread(cpu.node.getBlock()).sleep(cpu);
    }

    private boolean started() {
        return starttime != null;
    }

    public synchronized void pull() {
        try {
            Block block = node.getBlock();
            if (checkSuspended(block)) {
                return;
            }
            block.jobPulled();
            if (logger.isInfoEnabled()) {
                logger.info(block.getId() + ":" + getId() + " pull");
            }
            if (!started()) {
                sleep();
            }
            else if (running == null) {
                lastseq = block.getAllocationProcessor().getQueueSeq();
                running = block.getAllocationProcessor().request(endtime.subtract(Time.now()));
                if (running != null) {
                    running.getTask().addStatusListener(this);
                    running.start();
                    idleTime += timeDiff();
                    timelast = running.getEndTime();
                    if (timelast == null) {
                        CoasterService.error(20, "Timelast is null", new Throwable());
                    }
                    block.add(this);
                    submit(running);
                }
                else {
                    if (block.getAllocationProcessor().getQueued().size() == 0) {
                        sleep();
                    }
                    else {
                        sleep();
                    }
                }
            }
            else {
                CoasterService.error(40, "pull called while another job was running",
                    new Throwable());
            }
        }
        catch (Exception e) {
            taskFailed("Failed pull", e);
            CoasterService.error(21, "Failed pull", e);
        }
    }
    
    private boolean checkSuspended(Block block) {
        if (block.isSuspended()) {
            block.cpuIsClear(this);
            return true;
        }
        else {
            return false;
        }
    }

    protected void submit(Job job) {
        Block block = node.getBlock();
        Task task = job.getTask();
        if (logger.isInfoEnabled()) {
            logger.info(block.getId() + ":" + getId() + " submitting " + task.getIdentity());
        }
        task.setStatus(Status.SUBMITTING);
        try {
            KarajanChannel channel =
                    ChannelManager.getManager().reserveChannel(node.getChannelContext());
            ChannelManager.getManager().reserveLongTerm(channel);
            SubmitJobCommand cmd = new SubmitJobCommand(task);
            cmd.setCompression(false);
            cmd.executeAsync(channel, this);
        }
        catch (Exception e) {
            logger.info(block.getId() + ":" + getId() + " submission failed " + task.getIdentity());
            taskFailed(null, e);
        }
    }

    public void shutdown() {
        Block block = node.getBlock();
        done.clear();
        if (running != null) {
            logger.info(block.getId() + "-" + id + ": Job still running while shutting down");
            running.fail("Shutting down worker", null);
        }
        node.shutdown();
    }

    public int compareTo(Cpu o) {
        TimeInterval diff = timelast.subtract(o.timelast);
        if (diff.getMilliseconds() == 0) {
            return id - o.id;
        }
        else {
            return (int) diff.getMilliseconds();
        }
    }

    public synchronized Job getRunning() {
        return running;
    }

    public Time getTimeLast() {
        if (running != null) {
            if (timelast.isGreaterThan(Time.now())) {
                return timelast;
            }
            else {
                return Time.now();
            }
        }
        else {
            return timelast;
        }
    }

    public String toString() {
        return id + ":" + timelast;
    }

    public List<Job> getDoneJobs() {
        return done;
    }

    public void taskFailed(String msg, Exception e) {
        Block block = node.getBlock();
        if (running == null) {
            if (starttime == null) {
                starttime = Time.now();
            }
            if (endtime == null) {
                endtime = starttime.add(block.getWalltime());
            }
            running = block.getAllocationProcessor().request(endtime.subtract(Time.now()));
        }
        if (running != null) {
            running.fail("Task failed: " + msg, e);
        }
    }

    public void errorReceived(Command cmd, String msg, Exception t) {
        taskFailed(msg, t);
    }

    public void replyReceived(Command cmd) {
        SubmitJobCommand sjc = (SubmitJobCommand) cmd;
        Task task = sjc.getTask();
        task.setStatus(Status.SUBMITTED);
    }

    private static class PullThread extends Thread {
        private LinkedList<Cpu> queue, sleeping;
        private long sleepTime, runTime, last, print;
        private BlockQueueProcessor bqp;

        public PullThread(BlockQueueProcessor bqp) {
            this.bqp = bqp;
            setName("Job pull");
            setDaemon(true);
            queue = new LinkedList<Cpu>();
            sleeping = new LinkedList<Cpu>();
        }

        public synchronized void enqueue(Cpu cpu) {
            queue.add(cpu);
            notify();
        }

        public synchronized void sleep(Cpu cpu) {
            sleeping.add(cpu);
        }

        public void run() {
            last = System.currentTimeMillis();
            while (true) {
                Cpu cpu;
                synchronized (this) {
                    while (queue.isEmpty()) {
                        if (!awakeUseable()) {
                            try {
                                mwait(50);
                            }
                            catch (InterruptedException e) {
                                return;
                            }
                        }
                    }
                    cpu = queue.removeFirst();
                }
                cpu.pull();
            }
        }

        private boolean awakeUseable() {
            int seq = bqp.getQueueSeq();
            Iterator<Cpu> i = sleeping.iterator();
            int sz = sleeping.size();
            while (i.hasNext()) {
                Cpu cpu = i.next();
                if (cpu.lastseq < seq) {
                    enqueue(cpu);
                    i.remove();
                }
            }
            return sz != sleeping.size();
        }

        private void mwait(int ms) throws InterruptedException {
            runTime += countAndResetTime();
            wait(ms);
            sleepTime += countAndResetTime();
            if (runTime + sleepTime > 10000) {
                logger.info("runTime: " + runTime + ", sleepTime: " + sleepTime);
                runTime = 0;
                sleepTime = 0;
            }
        }

        private long countAndResetTime() {
            long t = System.currentTimeMillis();
            long d = t - last;
            last = t;
            return d;
        }
    }

    public synchronized void statusChanged(StatusEvent event) {
        if (event.getStatus().isTerminal()) {
            running.getTask().removeStatusListener(this);
            running.setEndTime(Time.now());
            jobTerminated();
        }
    }

    public int getId() {
        return id;
    }

    public void setId(int id) {
        this.id = id;
    }

    public void setRunning(Job r) {
        this.running = r;
    }

    public void addDoneJob(Job d) {
        done.add(d);
    }
}