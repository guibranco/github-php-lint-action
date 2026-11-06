<?php

namespace Example;

class Greeter
{
    private $greeting;

    public function __construct($greeting = 'Hello')
    {
        $this->greeting = $greeting;
    }

    public function greet($name)
    {
        return sprintf('%s, %s!', $this->greeting, $name);
    }
}
