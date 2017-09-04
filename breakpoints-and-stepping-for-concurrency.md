<!--
What's the goal of this article/post?

 - show what's possible with truffle
 - point out 'nice to have' things
-->

Building High-level Debuggers for Concurrent Languages with Truffle
===================================================================

> **Note:** This post is meant for people familiar with Truffle.
For introductory material, please see for instance this [list][intro].

With its [debugger support][add-debugger],
[Truffle][truffle] provides a rich foundation for custom debugging features
for a wide range of language concepts.

However, for our [implementation][SOMns] of [various breakpoint and stepping semantics][KomposProtocol]
for fork/join, threads and locks, software transactional memory, actors,
and communicating processes,
we needed a number of custom features,
which somewhat duplicate part of the framework.
One reason is that the debugger's granularity is on the level of nodes,
which can be too coarse-grained and requires restructuring the node implementations.
Another reason is that some important aspects of concurrency
are dealt with outside of the AST,
for instance, in an event loop like JavaScript has it.

This post details our experience with Truffle
and discusses the custom mechanisms that we implemented to deal with tradeoffs
such as implementation complexity and fine-grained breakpoint semantics.
Specifically, I am going into:

1. custom breakpoint checks
2. support for additional sequential stepping strategies
3. support for activity-specific stepping strategies
4. expression breakpoints
5. Java conditions for breakpoints

### Examples for High-level Breakpoints and Stepping

Before I go into what we did and what Truffle could still provide,
I am going to briefly give some examples of what wanted to achieve.

Languages such as JavaScript or Newspeak have the notion of event loops.
Event loops provide a convenient abstraction to handle lightweight concurrency,
for instance to react to events generated in a user interface or from external sources.
However when debugging such applications,
the callback-based programming style, with or without promises,
inverts the control flow, and it becomes hard to reason about programs in a natural way.

In a debugger, it would thus be nice
to be able to step through the callbacks in a promise chain
and focus on their execution and effects.
In our debugger, we offer such a mechanism with *step to resolution*,
which breaks execution when callbacks are executed
following the current promise being resolved with a value.
On the operation that resolves the promise,
we can also set a corresponding breakpoint.
Thus, whenever we resolve a promise from the lexical location,
we trigger the debugger as soon as the callbacks are executed.

Let's look at a JavaScript example:

```JavaScript
let rootPromise = new Promise((resolve, _) => {
  console.log("chance to capture resolve() and execute it");
  resolve("Promise done");
});

rootPromise.then(msg => {
  console.log("Step 1");
  return "Next step";
}).then(msg => {
  console.log("Step 2");
  return "Final step";
});
```

Ideally, we would be able to set a breakpoint on the `resolve()` call in line 3,
which says that we want to break whenever a callback on the `rootPromise` is triggered.
In this case, it would only be the one on line 7.
Once reaching execution there, we might want to simply step to the next callback,
which is triggered by resolving the promise that's returned by `then()`, i.e.,
the one on line 10.

So, what exactly do we need in a Truffle language implementation
to realize such breakpoints and stepping operations?


### <a id="custom-bp"></a> 1. Custom Breakpoint Checks

One of the features not provided by Truffle is the ability to check for
breakpoint information within a language implementation.
The main reason is that everything should be done with wrapper nodes
of the instrumentation API.

Unfortunately, there are some cases where that is not convenient,
because we would need to restructure AST nodes.
Or more importantly, it is not sufficient,
because we need the information that a breakpoint was set
at another point in the execution,
and triggering it at the lexical location would not be useful.
This is for instance the case for the example with the promises above.

To realize such promise breakpoints and stepping in SOMns,
we set a flag for the breakpoint on the 'message'
that is going to lead to the promise resolution.
This looks something like this:

```Java
@Child BreakpointNode promiseResolverBreakpoint;

@Specialization
void sendPromiseMessage(Object[] args, Promise rcvr) {
  PromiseSendMessage msg = new PromiseSendMessage(args, rcvr,
      promiseResolverBreakpoint.executeShouldHalt());
  msg.send();
}
```

The key here is `promiseResolverBreakpoint`,
which is an instance of our own `BreakpointNode`.
The `BreakpointNode` works similar to Truffle's builtin breakpoints
and specializes itself on whether the breakpoint is set or not.
So that at run time, there would not be any overhead for checking it,
since it merely needs to return `true` or `false` as a compile-time constant.

One important difference to normal Truffle breakpoints is that our breakpoint nodes
do not only have a source location, but also a type.
This enables us to distinguish various different types of breakpoints
for the same source location,
which is important if one wants more complex operations than
single stepping and line breakpoints.

The breakpoint node is roughly implemented as follows:

```Java
public abstract class BreakpointNode {

  protected final BreakpointEnabling bE;

  protected BreakpointNode(final BreakpointEnabling breakpoint) {
    this.bE = breakpoint;
  }

  public abstract boolean executeShouldHalt();

  @Specialization(assumptions = "bEUnchanged", guards = "!bE.enabled")
  public final boolean breakpointDisabled(
      @Cached("bE.unchanged") final Assumption bEUnchanged) {
    return false;
  }

  @Specialization(assumptions = "bEUnchanged", guards = "bE.enabled")
  public final boolean breakpointEnabled(
      @Cached("bE.unchanged") final Assumption bEUnchanged) {
    return true;
  }
}

public final class BreakpointEnabling {
  public boolean              enabled;
  public transient Assumption unchanged;

  BreakpointEnabling() {
    this.unchanged = Truffle.getRuntime().createAssumption("unchanged breakpoint");
    this.enabled = breakpointInfo.isEnabled();
  }

  public synchronized void setEnabled(final boolean enabled) {
    if (this.enabled != enabled) {
      this.enabled = enabled;
      this.unchanged.invalidate();
      this.unchanged = Truffle.getRuntime().createAssumption("unchanged breakpoint");
    }
  }
}
```

With this node in place, we can efficiently determine whether a breakpoint is set.
When scheduling a callback, we can now check the flag on the message
to see whether a breakpoint was set at the sending side.
Triggering the breakpoint is however a little bit more involved,
because we want it to trigger in the right position,
but such callbacks are handled by event loops outside of a Truffle AST.
This is going to be detailed in the next section.

For other types of breakpoints, it might be simpler,
because we might already be at the right place in the AST.
For these cases, we simple construct a node marked with Truffle's `AlwaysHalt` tag,
which ensures the debugger will trigger a breakpoint for us.
After checking the condition, we simply execute the node like this:

```Java
@Specialization
Object doSomethingComplex(...) {
  // ...
  if (obj.breakpointWasSet) {
    suspendExec.executeGeneric(frame); // tagged with AlwaysHalt, triggers debugger
  }
  // ...
}
```

This ensures that Truffle triggers the breakpoint
and uses its normal facilities to obtain information
about current stack and local variables in the debugger.

### 2. Support for Additional Sequential Stepping Strategies

Back to the example of breaking when a callback is triggered from a promise.

As mentioned before,
the main problem here is that we have the relevant information outside of the Truffle AST.
This means, we cannot really trigger a debugger, and even if we could,
the available state would possibly be confusing and not very helpful for the developers.
What we do instead is to use a *stepping strategy* to execute the callback
until it reaches a useful point.
Fortunately, Truffle already has the notion of a `RootTag`
to mark the first node of method that belongs to
what a developer would consider
the body of a method, i.e., ignoring possible pro- and epilogs.

We added a corresponding stepping strategy to Truffle to be able to say:
execute this method until you reach the first node tagged with `RootTag`.

This is implemented in the following class:

```Java
class StepUntilNextRootNode extends SteppingStrategy {
  @Override
  boolean step(DebuggerSession s, EventContext ctx, SteppingLocation location) {
    return location == SteppingLocation.BEFORE_ROOT_NODE;
  }
}
```

For other kind of breakpoints,
we also like to be able to step to the point after executing the root node.
For that case we added a `StepAfterNextRootNode` strategy.
This one is a little bit more complex,
because we need to remember the first root found,
and only trigger a suspension when we are in the `AFTER_ROOT_NODE` location for the same root node,
and for the same stack height.
This is necessary to account for recursion.
Note, the `AFTER_ROOT_NODE` location is also a custom addition
and comes with the corresponding `AFTER_STATEMENT` location,
which allow us to set breakpoints
or step to the point after which a node is executed.

Overall, I find stepping strategies a rather useful way of expressing
what the debugger should do,
and stopping after the execution of a node seems also useful.
Unfortunately, the current design in Truffle does not support any extension by tools.
While we only desired to step before and after (root) nodes
for sequential debugging so far,
general stepping strategies are another topic.

### 3. Activity-specific Stepping Strategies

To implement stepping from one turn of the event loop to the next, we use
an entirely custom approach to stepping strategies.
But the next turn is only one possible point we are interested in.
Others could be more specific to a promise or a message
to break at a corresponding callback or when the message is received.

For the various stepping operations,
we have a thread-local field with the strategy,
which then can be checked, depending on the type of strategy,
either in the event loop or in the `BreakpointNode`.

In our event loop, we currently check for instance for the stepping to the next turn
and to return to a promise resolution,
which corresponds to following execution to the next promise chained to a `then(.)` in the JavaScript example from the beginning.
In these cases, we set flags on the activity or promise objects
to indicate a breakpoint later on.

For other stepping operations, for instance step to next promise resolution,
we rely on a check in the `BreakpointNode`.

The previously shown code of `BreakpointNode` ignored this detailed.
So, it should look more like this:

```Java
@Specialization(assumptions = "bpUnchanged", guards = "!bp.enabled")
public final boolean breakpointDisabled(
    @Cached("bp.unchanged") final Assumption bpUnchanged) {
  return breakpoint.getSteppingType().isSet();
}
```

This means, if the breakpoint is disabled,
we check whether the thread-local field with the stepping strategy is set
to the type of the current breakpoint.
This check is conditional on whether debugging is enabled,
but has an overhead on the peak performance during a debugging session.

This seems to duplicate quite some of the mechanisms already included in Truffle
for stepping.
However, since we need different types of stepping strategies,
it did not seem possible to integrate it into Truffle
without approaching the question of how to design it in an extensible way.

### 4. Expression Breakpoints

After talking about the dynamics of breakpoints
let's briefly switch to setting breakpoints from a user interface.
As you might imagine,
that's somewhat relevant to support fancy breakpoints in an IDE
and expose them to users.

The biggest gap Truffle currently has here is
that it misses an API to set breakpoints on expressions.
Its `Breakpoint.Builder` currently only supports setting breakpoints on lines.
If we consider the earlier JavaScript example with promises,
we might want to set breakpoints on the `then(.)` or `resolve(.)` method calls,
and perhaps chose what type of breakpoint to set.
We could break just before executing the methods
or when their consequences take effect.

We actually take two different approaches to the problem.
For some use cases, for instance breaking before a call to `resolve(.)`,
we use a custom extension of the `Breakpoint.Builder`
that supports filtering by source section in terms of line number, column,
and section length, as well as a specific tag for the source section.
So, in this case,
we just rely on Truffle's breakpoints with a more fine-grained way of setting them.

For other case, we completely manage the breakpoints ourselves
with the aforementioned `BreakpointNode`, as discussed in [sec. 1](#custom-bp).

### 5. Java Conditions for Breakpoints

One final mechanism we rely on
is the ability to set simple Java conditions on breakpoints.
Currently, Truffle only supports setting conditions from the language itself.
Thus, I could set a JavaScript condition to break on a line
if some condition holds,
for instance a variable has a certain value.
However, there is no corresponding support to set conditions inside the implementation.

Our use case it to set breakpoints on functions that are triggered my messages,
or in JavaScript it would correspond to set a breakpoint specifically for the case
that a function is directly executed from the even loop, i.e., as a callback.
This can be helpful for stepping
or to trigger a breakpoint only for the case one is specifically interested in.

To realize this, we extended `Breakpoint` with a simple callback that returns a boolean.
We use it to check whether the calling method is of a specific type,
which signifies in SOMns that a method/function was activated via a message send,
i.e., from the event loop.

### Conclusion

In this post, I discussed a number of things
we need to do in [SOMns][SOMns]
to get advanced breakpoints for various concurrency models.
Some of these duplicate mechanisms in Truffle,
which could perhaps just be leveraged if they would be designed to be more extensible.
This includes the notion of breakpoints,
which should allow the notion of different types on the same line/expression.
It also includes nodes that allow run-time queries of a breakpoint status
to propagate it as part of the application,
and stepping strategies that can be queried and acted upon outside the Truffle AST,
i.e., for instance as part of an event loop.

The other things I am missing in Truffle could be offered
by extending the existing implementation.
This includes additional sequential stepping strategies and locations,
expression breakpoints, and simple condition on breakpoints.

These facilities could make a major difference
for people interested in building better debuggers for dynamic languages.
Looking at other people's debuggers, for instance [IntelliJ IDEA's Java support][intellij] or Chrome's [step into async][chrome-async],
their extensions look cool and very helpful,
but with the power we have in Truffle,
they are more than trivial!
It's a shame to leave all the potential unused.
Dynamic languages such as Ruby, JavaScript, Python, or R
could really benefit from great debuggers,
because most productive development is done in the debugger,
where you see what you do.

[intro]: https://gist.github.com/smarr/d1f8f2101b5cc8e14e12
[add-debugger]: http://stefan-marr.de/2016/04/adding-debugging-support-to-a-truffle-language/
[truffle]: http://graalvm.github.io/graal
[SOMns]: https://github.com/smarr/SOMns
[KomposProtocol]: http://stefan-marr.de/papers/dls-marr-et-al-concurrency-agnostic-protocol-for-debugging/
[intellij]: https://blog.jetbrains.com/idea/tag/debugger/
[chrome-async]: https://developers.google.com/web/updates/2017/05/devtools-release-notes#step-into-async
