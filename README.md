# em_filter

[![Hex.pm](https://img.shields.io/hexpm/v/em_filter.svg?color=darkgreen)](https://hex.pm/packages/em_filter)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/em_filter)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

An Erlang library for registering Emergence filters with a discovery service.

## Features

- Finds available ports for your filter service
- Registers your filter with a discovery service
- Simplifies filter management

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {em_filter, "0.3.0"}
]}.
