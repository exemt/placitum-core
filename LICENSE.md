# Placitum License Agreement

Version 1.1 of 12 September 2026

This agreement (the **Agreement**) is made between the rights holder of the Placitum product (the
**Licensor**) and the person or organization that installs, runs, studies or modifies the Product
(the **Licensee**). By installing the Product, opening its control panel or using its source code,
the Licensee accepts the Agreement in full. A Licensee who does not agree with the terms may not
use the Product.

> **In short.** This box is a convenience summary and is not part of the Agreement.
>
> - The Product is free for your own needs while the load on an installation stays within 100
>   requests per second.
> - Educational organizations of any country may use it free of charge with no load limit.
> - The source code is open: it may be studied and modified within the same free use.
> - Not free: load above 100 requests per second, and any commercial services around the Product
>   (installing, configuring, maintaining, supporting or operating it for others, or offering
>   protection by it as a service). These require a Commercial License.
> - Free use comes with no support, no warranty and no liability, and without feeds: address
>   lists, bot lists and rule updates are maintained by the Licensee.
> - Licenses for third-party components and databases (IP databases, rule sets, models) are the
>   Licensee's responsibility.
> - The Product may not be redistributed, resold or passed off as one's own.

## 1. Definitions

**Product** means the Placitum software suite: the nginx module, the controller and its control
panel, the node agent, the keeper service, the logging service, the inspectors (including the IP
filter, traffic rules, second factor, captcha, specification admission, counter, classifier,
response rewriting, automatic actions), the geo data service, command-line tools, deployment
scripts, documentation and other materials the Licensor ships with them, both as source code and as
built images and executables. Third-Party Components and Feeds are not part of the Product.

**Installation** means one Product controller together with all nginx nodes it delivers
configuration to and the inspectors that work with it.

**Load** of an Installation means the number of HTTP requests handled by the Product module on all
nodes of the Installation in total, divided by the length of the measurement interval. A WebSocket
handshake counts as one request; individual WebSocket frames are not counted. The measurement
interval is five consecutive minutes.

**Threshold** means 100 (one hundred) requests per second.

**Day of Excess** means a calendar day during which the Load of the Installation exceeded the
Threshold in at least one measurement interval.

**Own Needs** means use of the Product by the Licensee to protect web applications and APIs that
the Licensee itself operates for its own activity, including the Licensee's commercial activity
that is not related to the Product. An application the Licensee operates for its own customers is
still the Licensee's own application. Protecting applications operated by third parties is not Own
Needs.

**Commercial Services** means any activity for remuneration or other commercial benefit that
consists in or is connected with installing, configuring, maintaining, supporting, operating or
hosting the Product for third parties, including offering protection by the Product as a service,
consulting on the Product and reselling it.

**Educational Organization** means an organization of any country whose principal activity is
teaching: a school, college, vocational school, university, institute, academy, training centre,
kindergarten, library or a research organization attached to them, public or private, regardless of
form of ownership.

**Feeds** means updatable content the Licensor may publish for the Product: lists of addresses,
networks, autonomous systems, bots and other unwanted sources, reputation data, rule sets,
signatures, machine-learning models and similar material, and the service that delivers updates of
such content.

**Third-Party Components** means software, data and services created by parties other than the
Licensor that the Product uses, includes in its images or scripts, or is designed to work with,
such as nginx, libmodsecurity, the OWASP Core Rule Set, NATS, Redis, ClickHouse, PostgreSQL,
HAProxy, geo and IP databases (for example MaxMind), IP reputation sources, machine-learning models
and programming-language libraries.

**Commercial License** means a separate written contract between the Licensor and the Licensee that
permits use of the Product beyond the terms of this Agreement.

## 2. Free license

Subject to the Agreement, the Licensor grants the Licensee a non-exclusive, worldwide, royalty-free
and non-transferable license to:

1. install and run the Product for Own Needs in any number of Installations whose Load does not
   exceed the Threshold;
2. make copies of the Product needed to install, back up and operate it within the Licensee's
   organization;
3. study the source code of the Product;
4. modify the source code of the Product and run modified versions on the same terms as the
   unmodified Product;
5. hand the Product and its modified versions to a contractor who installs or operates an
   Installation on behalf of the Licensee, provided the contractor is bound not to use or distribute
   the Product otherwise. Whether the contractor itself needs a Commercial License is governed by
   section 4.

All rights not expressly granted are reserved by the Licensor.

## 3. Load threshold

3.1. The free license under section 2 is limited by the Threshold. The Threshold applies to each
Installation separately.

3.2. An Installation is deemed to have exceeded the Threshold when more than 3 (three) Days of
Excess accumulate within any 30 (thirty) consecutive calendar days. Short bursts within this
allowance do not require a license.

3.3. Splitting one web application across several Installations in order to stay under the
Threshold is not permitted: the Load of such Installations is summed and treated as the Load of a
single Installation.

3.4. The Licensee monitors the Load. The Product displays it in the control panel, but missing or
inaccurate readings do not relieve the Licensee from observing the Threshold. On the Licensor's
request the Licensee confirms in writing the Load of its Installations.

3.5. If an Installation has exceeded the Threshold, the Licensee shall within 30 (thirty) calendar
days either conclude a Commercial License, obtain the Licensor's written permission, or reduce the
Load below the Threshold. Use of the Installation before this period ends is not a breach.

3.6. To evaluate the Product under real load, the Licensee may exceed the Threshold once for 30
(thirty) calendar days from the first start of an Installation without a Commercial License.

## 4. Own needs and commercial services

4.1. The free license covers Own Needs only.

4.2. Providing Commercial Services requires a Commercial License or the Licensor's written
permission regardless of Load. The requirement applies to the party providing the services. The
customer of such services keeps its own free license under section 2 if it otherwise qualifies.

4.3. Installation, configuration and maintenance of the Product by the Licensee's own employees for
the Licensee's Installations is Own Needs.

4.4. Offering protection by the Product as a service to third parties (for example, by a hosting
provider, a managed security provider or a system integrator) is Commercial Services.

## 5. Educational organizations

5.1. Educational Organizations of any country receive the Product free of charge on the terms of
section 2 with no Load limit: the Threshold does not apply to them.

5.2. The exemption covers the organization's own information systems, including systems a
contractor installs and operates for it. Section 4 still applies to the contractor.

5.3. The exemption does not extend to companies for which education is the market for their own
product or service (for example, commercial online-course platforms), unless the company itself is
an Educational Organization.

5.4. The Licensor may request confirmation of the organization's status; the Licensee provides it
within a reasonable time.

## 6. Commercial license

6.1. Using an Installation with Load above the Threshold, except as provided in sections 3.5, 3.6
and 5, and providing Commercial Services require a Commercial License or the Licensor's written
permission.

6.2. The terms of a Commercial License, such as price, term, number of Installations, support and
Feeds, are agreed separately. Written permission of the Licensor given by e-mail is equivalent to a
Commercial License to the extent stated in it.

6.3. A Commercial License supplements this Agreement and does not replace it: whatever the
Commercial License does not expressly permit remains governed by the Agreement.

## 7. Source code: study and modification

7.1. The source code of the Product is open for study by anyone.

7.2. The Licensee may modify the source code and build its own versions of the Product. Modified
versions remain the Product within the meaning of the Agreement: the same permissions and the same
restrictions, including the Threshold and section 4, apply to them.

7.3. All copies and modified versions keep the authorship notices, the text of this Agreement, the
acceptance window and the link to the Agreement in the control panel.

7.4. The Licensor is not obliged to accept, support or maintain changes made by the Licensee.

## 8. What is prohibited

Without the Licensor's separate written permission the Licensee may not:

1. distribute the Product or its modified versions to third parties, including selling, renting,
   sublicensing, publishing openly or bundling into another product, other than handing it to a
   contractor under clause 2.5;
2. provide Commercial Services without a Commercial License;
3. remove, hide or bypass authorship notices, the acceptance window or the link to the Agreement,
   or pass the Product off as its own development, including under a different name;
4. use the Product to break the law or to infringe the rights of third parties.

## 9. No support under the free license

9.1. Under the free license the Licensor provides no support of any kind: it is not obliged to
answer questions, fix errors, publish updates, review the Licensee's configuration or help with
installation, operation or incidents.

9.2. Support, response times and error fixing are provided only under a Commercial License and to
the extent stated in it.

9.3. Anything the Licensor nevertheless does for a Licensee under the free license is done
voluntarily, creates no obligation to continue and does not change section 17 or 18.

## 10. Feeds and updates

10.1. Feeds are not part of the free license. Address and network lists, bot lists, lists of
unwanted sources, rule sets, signatures, models and their updates are maintained by the Licensee on
its own.

10.2. Feeds, their delivery and automatic updating are provided only under a Commercial License and
to the extent stated in it. The Licensor may make automatic updating unavailable or disable it for
Installations without a Commercial License.

10.3. Feeds published by the Licensor may include Third-Party Components; section 11 applies to
them.

## 11. Third-party components and databases

11.1. Third-Party Components are used under their own licenses and terms, and this Agreement does
not change those terms. The Licensor grants no rights to Third-Party Components.

11.2. Where a Third-Party Component or database requires its own license, registration, key,
subscription or payment (for example, geo and IP databases, IP reputation sources, commercial rule
sets, models), obtaining it, paying for it and complying with its terms is the Licensee's
obligation. The Licensee uses such components under its own agreements with their providers.

11.3. The Licensor is not liable for the availability, accuracy or terms of Third-Party Components
or for the consequences of their use.

## 12. Data processed by the Product

12.1. The Product processes the traffic of the protected applications, including personal data
contained in it. The Licensee determines the purposes and means of such processing and is
responsible for compliance with data protection, privacy and other applicable laws, including
informing users where required.

12.2. The Licensor has no access to data processed by the Licensee's Installations and does not
receive it, unless the Licensee sends it to the Licensor on its own initiative.

## 13. Control panel and acceptance

13.1. On the first entry into the control panel the Product shows the text of the Agreement and
requires it to be accepted. Pressing the accept button is the consent of the person working with the
panel to the terms of the Agreement on behalf of the organization in whose interest the Installation
is operated.

13.2. The acceptance mark is stored in the browser. Its absence in another browser or after
clearing browser data does not mean the Agreement has not been accepted: it is accepted from the
first use of the Product.

13.3. When a new version of the Agreement is released, the panel shows it again. Until the new
version is accepted, the Installation keeps running on the terms of the version the copy of the
Product came with.

## 14. Trademarks

The name "Placitum", the logo and the visual identity belong to the Licensor. The Agreement does
not grant the right to use them other than to state that an Installation is built on the Product.

## 15. Contributions

By submitting fixes, additions or other materials to the Licensor for inclusion in the Product, the
Licensee grants the Licensor a perpetual, irrevocable, worldwide and royalty-free right to use,
modify, distribute and sublicense those materials on any terms, including commercial ones. The
Licensee confirms it is entitled to submit such materials.

## 16. Security research

Studying the Product for vulnerabilities in the Licensee's own Installations is permitted. The
Licensee is asked to report a found vulnerability to the Licensor before making it public and to
give the Licensor a reasonable time to fix it.

## 17. No warranty

The Product and its source code are provided "as is", without warranties of any kind, express or
implied, including fitness for a particular purpose, absence of errors, uninterrupted operation,
compatibility with the Licensee's environment and protection from any attacks. The Licensee assesses
the suitability of the Product and bears the risk of its use. The Product is under development: some
functions may be incomplete, and the Licensor is not obliged to complete or keep them.

## 18. Limitation of liability

18.1. Under the free license the Licensor bears no liability for the operation of the Product or
its source code and for damages of any kind arising from their use or inability to use them: lost
profit, loss of data, business interruption, reputational harm, blocking of legitimate users, or the
consequences of attacks the Product did not stop.

18.2. Under a Commercial License the Licensor's liability is defined by that license and, unless it
states otherwise, is limited to the amount the Licensee paid for the Product over the last twelve
months.

18.3. Nothing in the Agreement limits liability that cannot be limited under applicable law.

## 19. Indemnity

The Licensee indemnifies the Licensor against third-party claims arising from the Licensee's use of
the Product, including claims of users of the protected applications, claims related to data
processing and claims related to Third-Party Components used by the Licensee.

## 20. Term and termination

20.1. The Agreement is effective from acceptance until termination.

20.2. The Agreement terminates automatically if the Licensee breaches it and fails to cure the
breach within 30 (thirty) calendar days after the Licensor's written notice. For breaches of
section 8 the Licensor may terminate the Agreement immediately.

20.3. Upon termination the Licensee stops using the Product and deletes its copies. Sections 11,
12, 14, 15, 17, 18, 19, 22 and 23 survive termination.

## 21. Versions of the Agreement and of the Product

21.1. The Licensor may publish new versions of the Agreement. A copy of the Product received with a
particular version of the Agreement is used on the terms of that version. A new version applies to
the Licensee from the moment it is accepted in the control panel or a new copy of the Product is
received.

21.2. The Licensor may change the Product, release new versions on different terms, and stop
developing or distributing it. The Licensor is not obliged to publish updates.

## 22. General provisions

22.1. If any provision of the Agreement is found invalid, the remaining provisions stay in force,
and the invalid provision is replaced by a valid one closest in meaning.

22.2. The Licensee may not assign the Agreement or its rights under it without the Licensor's
written consent. The Licensor may assign the Agreement to a successor of the rights to the Product.

22.3. The Licensor's failure to enforce a provision is not a waiver of it.

22.4. The Licensee complies with export control and sanctions laws applicable to it when using the
Product.

22.5. Notices under the Agreement are given by e-mail to the address in the Contacts section and to
the address the Licensee provided to the Licensor.

22.6. The Agreement, together with a Commercial License where one exists, is the entire agreement
between the parties regarding the Product.

## 23. Governing law and language

23.1. The Agreement is governed by the law of the country in which the Licensor is registered or
permanently resides at the time a dispute arises. Disputes are resolved at the Licensor's location
unless mandatory rules of law require otherwise.

23.2. The Agreement is written in English, and the English text governs its interpretation.
Translations into other languages, including the Russian text shipped with the Product, are provided
for convenience; in case of discrepancy the English text prevails.

## Contacts

Questions about a Commercial License, permission to provide Commercial Services or to use above the
Threshold, Feeds, support and confirmation of an organization's status: public.gerden@gmail.com.
