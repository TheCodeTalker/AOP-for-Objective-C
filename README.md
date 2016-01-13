AOPAspect is a small aspect oriented programming library for iOS. Licensed under the MIT license.

**Note:** Current implementation is **not thread safe** for dynamically hooking/unhooking methods on multiple levels of a class hierarchy. Be extra careful.

Because of how the hooking mechanism works, a limitation of the current implementation is that it won't run aspects when calling super on overriden methods (e.g.: -[UIViewController viewDidAppear:animated]); only the leaf call has its aspects processed[1].

For more information on how it works, please check out the article by the original author:

<http://codeshaker.blogspot.com/2012/01/aop-delivered.html>



[1] A thread-safe workaround is being devised (use a different method than _objc_msgForward[and variants] and keep the depth level on the current thread dictionary to control which super-version to call) but this is only an unproven idea.
