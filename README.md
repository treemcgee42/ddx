# ddx

If you want to write math, you ostensibly have two choices: 
- Write LaTeX. You'll have full custimization of the PDF output,
but run into some issues displaying it on the web.
Many opt to simply upload the PDF itself.
- Write using an extending Markdown syntax or something similar.
In this approach you are limited in the typsetting functionality available to you,
which may result in non-ideal web and/or print output.

The goal of this project is to provide pretty conversions from LaTeX to HTML. 
That way, you can write your notes once and get beautiful PDF and web output.

A non-goal of this project is be a full LaTeX compiler. 
We purposefully ignore certain LaTeX commands, 
and hand-pick ones to provide Astro components for. 
Let us know if there is a feature you would like to have,
or feel free to add it yourself!

## Design

The process can be proken down into three stages:
- LaTeX parsing.
This is by no means complete,
and encodes just enough semantics for the next stage.
- "TSX" generation.
Using the parsed source code, we generate an Astro file.
[Astro](https://astro.build/) is a "meta" framework that allows us to create components with similar semantics to LaTeX segments,
e.g. an "Equation" component for a LaTeX "equation" environment.
- HTML/JS generation.
We then build the Astro file, which gives us corresponding HTML/JS.
Since Astro does not include any frameworks like React by default, it is extremely lightweight.
In fact, it is possible that the generated code will not include any JS at all,
having been entirely interpreted at compile-time!

## Contributing

Please contact me if you're interested! 
Right now I'm developing this project with my own use cae in mind, 
but if there's interest some feature or aspect I'm happy to consider it.

I also feel the LaTeX parser could potentially be abstracted into a standalone program or library.
Again, if that's something that interests you please let me know.

## FAQs

**What alternatives are there?**

- [pandoc](https://pandoc.org/) includes a LaTeX to HTML converter. 
It's pretty good, but this project aims to be more extensible, and customizable.
- An early motivation for this project was [nLab](https://ncatlab.org/nlab/show/HomePage), which uses a fork of [instiki](https://golem.ph.utexas.edu/wiki/instiki/show/HomePage).
However, these projects are geared towards a "wiki" application,
meaning they have to support in-browser editing.
This ultimately means these sites need a backend database.
For such purposes this isn't avoidable,
but for personal or smaller-scale projects it is preferable to have a static site with no backend.
Static sites can be deployed easier and even freely, e.g. through [Github pages](https://pages.github.com/).
