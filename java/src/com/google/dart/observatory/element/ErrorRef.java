/*
 * Copyright (c) 2015, the Dart project authors.
 *
 * Licensed under the Eclipse Public License v1.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 *
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */
package com.google.dart.observatory.element;

// This is a generated file.

import com.google.gson.JsonObject;

/**
 * [ErrorRef] is a reference to an [Error].
 */
public class ErrorRef extends Element {

  public ErrorRef(JsonObject json) {
    super(json);
  }

  /**
   * What kind of error is this?
   */
  public ErrorKind getKind() {
    return ErrorKind.valueOf(((JsonObject) json.get("kind")).getAsString());
  }

  /**
   * A description of the error.
   */
  public String getMessage() {
    return json.get("message").getAsString();
  }
}
